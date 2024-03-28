LiveSearch = {
	init: function() {
		var input = Ext.get('headerSearchInput');
		var button = Ext.get('headerSearchBtn');

		if (input && button) {
			button.on({
				mouseover: function(){
					input.setDisplayed(true);
					input.focus();
				}
			});

			if (!hideSearchTimer)
				hideSearchTimer = new Ext.util.DelayedTask();
			
			input.on({
				click: function() { hideSearchTimer.cancel(); },
				focus: function() { hideSearchTimer.cancel(); },
				blur: function(){ hideSearchTimer.delay(2000); }
			});

			sinput = new Ext.form.TextField({
				applyTo: input,
				validationDelay: 100,
				validateOnBlur: false,
				selectOnFocus: true,

				searchMenu: new Ext.menu.Menu({
					width: 250,
					autoScroll: false,
					maxHeight: document.height - 300,
					items: [],
					show: function() {
						if (!this.el)
							this.render();

						var xy = [input.getX(), input.getY() + input.getHeight()];

						// set the position so we can figure out the constrain value.
						this.el.setXY(xy);
						//constrain the value, keep the y coordinate the same
						xy[1] = this.constrainScroll(xy[1]);
						xy = [this.el.adjustForConstraints(xy)[0], xy[1]];

						this.el.setXY(xy);
						this.el.show();
						Ext.menu.Menu.superclass.onShow.call(this);
						if(Ext.isIE){
							// internal event, used so we don't couple the layout to the menu
							this.fireEvent('autosize', this);
							if (!Ext.isIE8){
								this.el.repaint();
							}
						}
						this.hidden = false;
						this.fireEvent('show', this);
					},

					links : {
						track: new Ext.Template( webroot + 'songinfo.html?player={player}&item={id}'),
						album: new Ext.Template( webroot + 'clixmlbrowser/clicmd=browselibrary+items&mode=albums&linktitle=' + SqueezeJS.string('album') + '%20({title})&album_id={id}&player={player}/index.html?index=0'),
						work: new Ext.Template( webroot + 'clixmlbrowser/clicmd=browselibrary+items&mode=works&linktitle=' + SqueezeJS.string('works') + '%20({title})&work_id={id}&from_search={terms}&player={player}/index.html?index=0'),
						contributor: new Ext.Template( webroot + 'clixmlbrowser/clicmd=browselibrary+items&mode=albums&linktitle=' + SqueezeJS.string('artist') + '%20({title})&artist_id={id}&player={player}/'),
						search: new Ext.Template( webroot + 'clixmlbrowser/clicmd=browselibrary+items&linktitle=' + SqueezeJS.string('search') + '&mode=search/index.html?player={player}&index={id}&submit=Search&q={title}'),
						item: new Ext.Template( '<div>{title}<span class="browsedbControls"><img src="' + webroot + 'html/images/b_play.gif" id="play:{id}:{title}" class="livesearch-play">&nbsp;<img src="' + webroot + 'html/images/b_add.gif" id="add:{id}:{title}" class="livesearch-add"></span></div>')
					},
					
					listeners: {
						click: function(self, menuItem, e) {
							var target = e ? e.getTarget() : null;
							
							// check whether user clicked one of the playlist controls
							if ( target && Ext.id(target).match(/^(add|play)/) ) {
								self.playAddAction(target);

								return;
							}
							
							var type;
							if (menuItem.track_id) {
								type = 'track';
							}
							else if (menuItem.album_id) {
								type = 'album';
							}
							else if (menuItem.contributor_id) {
								type = 'contributor';
							}
							else if (menuItem.work_id) {
								type = 'work';
							}
							else if (menuItem.search_id != null) {
								type = 'search';
							}
							
							if (!type || !self.links[type]) {
								return;
							}
							
							location = self.links[type].apply({
								id: menuItem.track_id || menuItem.album_id || menuItem.contributor_id || menuItem.work_id || menuItem.search_id,
								title: encodeURIComponent(menuItem.search_id != null ? input.dom.value : menuItem.title),
								player: SqueezeJS.getPlayer(),
								terms: input.dom.value
							});
						},
						
						// don't hide the menu if add/play was pressed, the user might want to add more
						beforehide: function(self) {
							if (self.playActionTriggered) {
								delete self.playActionTriggered;
								return false;
							}
						},
						
						afterrender: function(self) {
							new Ext.KeyMap(self.id, {
								key: 'ap',
								fn: function(key, e) {
									if (!e)
										return;
									
									var selector;
									if (e.getKey() == e.A) {
										selector = 'img.livesearch-add';
									}
									else if (e.getKey() == e.P) {
										selector = 'img.livesearch-play';
									}

									if (selector) {
										var item = e.getTarget(null, null, true);
										if (item) {
											self.playAddAction(item.child(selector));
										}
									}
								}
							});
						}
					},
					
					playAddAction: function(target) {
						if (!target)
							return;
						
						var params = Ext.id(target).split(':');

						if (params.length > 2) {
							SqueezeJS.Controller.playerRequest({
								params: ['playlistcontrol', 'cmd:' + (params[0] == 'play' ? 'load' : params[0]), (params[1] == 'contributor_id' ? 'artist_id' : params[1]) + ':' + params[2] ],
								showBriefly: params.slice(3).join(':')
							});
							
							self.playActionTriggered = true;
						}
					}
				}),

				validator: function(value){
					if (value.length > 0) {
						SqueezeJS.Controller.playerRequest({
							params: [ 'search', 0, 5, 'term:' + value, 'extended:1' ],
							success: function(response){
								this.searchMenu.removeAll();
								
								if (response && response.responseText) {
									response = Ext.util.JSON.decode(response.responseText);
									var result = response.result;
									var tpl = this.searchMenu.links['item'];
									
									if (result.contributors_loop) {
										if (this.searchMenu.items.length > 0)
											this.searchMenu.addItem('-');
										
										this.searchMenu.addItem({
											text: '<b>' + SqueezeJS.string('artists') + '...</b>',
											icon: '/html/images/b_search.gif',
											search_id: 0
										});
										
										Ext.each(result.contributors_loop, function(item, index, allItems) {
											this.searchMenu.addItem({
												text: tpl.apply({
													title: item.contributor,
													id: 'contributor_id:' + item.contributor_id
												}),
												title: item.contributor,
												contributor_id: item.contributor_id
											});
										}, this);
									}
									
									if (result.albums_loop) {
										if (this.searchMenu.items.length > 0)
											this.searchMenu.addItem('-');
										
										this.searchMenu.addItem({
											text: '<b>' + SqueezeJS.string('albums') + '...</b>',
											icon: '/html/images/b_search.gif',
											search_id: 1
										});
										
										Ext.each(result.albums_loop, function(item, index, allItems) {
											this.searchMenu.addItem({
												text: tpl.apply({
													title: item.album,
													id: 'album_id:' + item.album_id
												}),
												title: item.album,
												icon: '/music/' + (item.artwork || 0) + '/cover_50x50_o',
												album_id: item.album_id
											});
										}, this);
									}
									
									if (result.works_loop) {
										if (this.searchMenu.items.length > 0)
											this.searchMenu.addItem('-');
										
										this.searchMenu.addItem({
											text: '<b>' + SqueezeJS.string('works') + '...</b>',
											icon: '/html/images/b_search.gif',
											search_id: 2
										});
										
										Ext.each(result.works_loop, function(item, index, allItems) {
											this.searchMenu.addItem({
												text: tpl.apply({
													title: item.work,
													id: 'work_id:' + item.work_id
												}),
												title: item.work,
												work_id: item.work_id
											});
										}, this);
									}
									
									if (result.tracks_loop) {
										if (this.searchMenu.items.length > 0)
											this.searchMenu.addItem('-');
										
										this.searchMenu.addItem({
											text: '<b>' + SqueezeJS.string('songs') + '...</b>',
											icon: '/html/images/b_search.gif',
											search_id: 3
										});
										
										Ext.each(result.tracks_loop, function(item, index, allItems) {
											this.searchMenu.addItem({
												text: tpl.apply({
													title: item.track,
													id: 'track_id:' + item.track_id
												}),
												title: item.track,
												icon: '/music/' + (item.coverid || 0) + '/cover_50x50_o',
												track_id: item.track_id
											});
										}, this);
									}
									
									if (this.searchMenu.items.length <= 0) {
										this.searchMenu.addItem({
											text: '<b>' + SqueezeJS.string('no_search_results') + '</b>'
										});
									}

									this.searchMenu.show();
								}
							},
							scope: this
						});
					}

					return true;
				},
				
				scope: this,

				// overwrite default filter to ignore key modifiers
				filterValidation : function(e){
					if ((!e.isNavKeyPress() && !e.isSpecialKey()) || e.getKey() == e.BACKSPACE) {
						this.validationTask.delay(this.validationDelay);
					}
				},
				
				listeners: {
					// validate as soon as the input gets the focus, so we don't lose the menu if we come back from the menu
					focus: function() {
						this.validationTask.delay(0);
					},
					specialkey: function(field, e) {
						if (e.getKey() == e.DOWN) {
							this.searchMenu.focus();
						}
					}
				}
			});
			
			hideSearchTimer = new Ext.util.DelayedTask(function(){
				if (sinput && sinput.searchMenu && sinput.searchMenu.isVisible()) {
					hideSearchTimer.delay(2000);
				} 
				else {
					input.setDisplayed(false);
				}
			});
			
			SqueezeJS.loadStrings(['ARTISTS', 'ARTIST', 'ALBUMS', 'ALBUM', 'WORKS', 'SONGS', 'NO_SEARCH_RESULTS', 'SEARCH']);
		}
	}
};
