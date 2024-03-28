package Slim::Control::Commands;

# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

################################################################################

=head1 NAME

Slim::Control::Commands

=head1 DESCRIPTION

Implements most Lyrion Music Server commands and is designed to be exclusively called
through Request.pm and the mechanisms it defines.

=cut

use strict;

use Scalar::Util qw(blessed looks_like_number);
use File::Spec::Functions qw(catfile);
use File::Basename qw(basename);
use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Alarm;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::OSDetect;
use Slim::Utils::Scanner::Local;

my $log = logger('control.command');

my $prefs = preferences('server');


sub abortScanCommand {
	my $request = shift;

	Slim::Music::Import->abortScan();

	$request->setStatusDone();
}


sub alarmCommand {
	# functions designed to execute requests have a single parameter, the
	# Request object
	my $request = shift;

	# check this is the correct command. In theory this should never happen
	# but we check anyway since it is easy to err in the big dispatch table.
	# Please check other commands for examples of more advanced usage of
	# isNotCommand for multi-term commands
	if ($request->isNotCommand([['alarm']])) {

		# set an appropriate error state. This will stop execute and callback
		# and notification, etc.
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters. In this case the parameters are defined here only
	# but for some commands, the parameters name start with _ and are defined
	# in the big dispatch table (see Request.pm).
	my $client      = $request->client();
	my $cmd         = $request->getParam('_cmd');

	my @tags = qw( id dow dowAdd dowDel enabled repeat time volume shufflemode playlisturl url cmd );

	# legacy support for "bare" alarm cli command (i.e., sending all tagged params)
	my $params;
	my $skip;
	if ($cmd =~ /:/) {
		my ( $tag, $val ) = split /:/, $cmd;
		$params->{$tag} = $val;
		$skip = $tag;
	} else {
		$params->{cmd} = $cmd;
		$skip = 'cmd';
	}

	for my $tag (@tags) {
		# skip this if we already got it from the _cmd param in the first slot of the command
		next if $tag eq $skip;
		$params->{$tag} = $request->getParam($tag);
	}

	# validate the parameters using request's convenient functions
	# take this command by command to avoid logical insanity

	# command needs to be one of 6 different things
	if ( $request->paramUndefinedOrNotOneOf($params->{cmd}, ['add', 'delete', 'update', 'enableall', 'disableall', 'defaultvolume' ]) ) {
		$request->setStatusBadParams();
		return;
	}

	# required param for 'defaultvolume' is volume
	if ( $params->{cmd} eq 'defaultvolume' && ! defined $params->{volume} ) {
		$request->setStatusBadParams();
		return;
	}

	# required param for 'add' is time, given as numbers only
	# client needs to be given
	# dow needs to be properly formatted
	if ( $params->{cmd} eq 'add' &&
		(
			! defined $params->{time} ||
			$params->{time} =~ /\D/ ||
			! defined $client ||
			( defined $params->{dow} && $params->{dow} !~ /^[0-6](?:,[0-6])*$/ )
		)
	) {
		$request->setStatusBadParams();
		return;
	}

	# required param for 'delete' is id, and needs a client
	if ( $params->{cmd} eq 'delete' && ( ! $params->{id} || ! $client ) ) {
		$request->setStatusBadParams();
		return;
	}

	# required param for 'update' is id, and needs a client
	if ( $params->{cmd} eq 'update' && ( ! $params->{id} || ! $client ) ) {
		$request->setStatusBadParams();
		return;
	}

	my $alarm;

	if ($params->{cmd} eq 'add') {
		$alarm = Slim::Utils::Alarm->new($client);
	}
	elsif ($params->{cmd} eq 'enableall') {
		$prefs->client($client)->alarmsEnabled(1);
	}
	elsif ($params->{cmd} eq 'disableall') {
		$prefs->client($client)->alarmsEnabled(0);
	}
	elsif ($params->{cmd} eq 'defaultvolume') {
		# set the volume
		Slim::Utils::Alarm->defaultVolume($client, $params->{volume});
	}
	else {
		$alarm = Slim::Utils::Alarm->getAlarm($client, $params->{id});
	}

	if (defined $alarm) {

		if ($params->{cmd} eq 'delete') {
			$alarm->delete;
		}

		else {

			$alarm->time($params->{time}) if defined $params->{time};
			# the playlisturl param is supported for backwards compatability
			# but url is preferred
			my $url = undef;
			if (defined $params->{url}) {
			  $url = $params->{url};
			} elsif (defined $params->{playlisturl}) {
			  $url = $params->{playlisturl};
			}

			if (defined $url) {
			  if ($url eq '0') {
				# special case for sending 0 for url/playlisturl
				# (needed for proper jive support for selecting "Current Playlist")
				$alarm->playlist(undef);
			  } else {
				$alarm->playlist($url);
			  }
			}

			$alarm->volume($params->{volume}) if defined $params->{volume};
			$alarm->shufflemode($params->{shufflemode}) if defined $params->{shufflemode};
			$alarm->enabled($params->{enabled}) if defined $params->{enabled};
			$alarm->repeat($params->{repeat}) if defined $params->{repeat};

			# handle dow tag, if defined
			if ( defined $params->{dow} ) {
				foreach (0..6) {
					my $set = $params->{dow} =~ /$_/;
					$alarm->day($_, $set);
				}
			}

			# allow for a dowAdd and dowDel param for adding/deleting individual days
			# these directives take precendence over anything that's in dow
			if ( defined $params->{dowAdd} ) {
				$alarm->day($params->{dowAdd}, 1);
			}
			if ( defined $params->{dowDel} ) {
				$alarm->day($params->{dowDel}, 0);
			}

			$alarm->save();

		}

		# we add a result for the benefit of the caller (in this case, most
		# likely the CLI).
		$request->addResult('id', $alarm->id);
	}

	# indicate the request is done. This enables execute to continue with
	# calling the callback and notifying, etc...
	$request->setStatusDone();
}


sub artworkspecCommand {
	my $request = shift;

	# get the parameters
	my $name = $request->getParam('_name') || '';
	my $spec = $request->getParam('_spec');

	# check this is the correct command.
	if ( !$spec || $request->isNotCommand([['artworkspec'], ['add']]) ) {
		$request->setStatusBadDispatch();
		return;
	}

	main::DEBUGLOG && $log->debug("Registering artwork resizing spec: $spec ($name)");

	# do some sanity checking
	my ($width, $height, $mode, $bgcolor, $ext) = Slim::Web::Graphics->parseSpec($spec);
	if ($width && $height && $mode) {
		my $specs = Storable::dclone($prefs->get('customArtSpecs'));

		my $oldName = $specs->{$spec};
		if ( $oldName && $oldName !~ /\Q$name\E/ ) {
			$specs->{$spec} = "$oldName, $name";
		}
		# don't duplicate standard specs!
		elsif ( !$oldName && !(scalar grep /$spec/, Slim::Music::Artwork::getResizeSpecs()) ) {
			$specs->{$spec} = $name;
		}

		$prefs->set('customArtSpecs', $specs);
	}
	else {
		$log->error('Invalid artwork resizing specification: ' . $spec);
	}

	$request->setStatusDone();
}


sub buttonCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['button']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client     = $request->client();
	my $button     = $request->getParam('_buttoncode');
	my $time       = $request->getParam('_time');
	my $orFunction = $request->getParam('_orFunction');

	if (!defined $button ) {
		$request->setStatusBadParams();
		return;
	}

	# if called from cli, json or comet then store this as the last button as we have bypassed the ir code
	if ($request->source) {
		$client->lastirbutton($button);
	}

	Slim::Hardware::IR::executeButton($client, $button, $time, undef, defined($orFunction) ? $orFunction : 1);

	$request->setStatusDone();
}


sub clientConnectCommand {
	my $request = shift;
	my $client  = $request->client();

	if ( $client->hasServ() ) {
		my ($host, $packed);
		$host = $request->getParam('_where');
		$host = Slim::Utils::Network::intip($host);

		if ( !$host ) {
			$request->setStatusBadParams();
			return;
		}

		if ($client->controller()->allPlayers() > 1) {
			my $syncgroupid = $prefs->client($client)->get('syncgroupid') || 0;
			$packed = pack 'NA10', $host, sprintf('%010d', $syncgroupid);
		} else {
			$packed = pack 'N', $host;
		}

		$client->execute([ 'stop' ]);

		foreach ($client->controller()->allPlayers()) {

			if ($_->hasServ()) {

				$_->sendFrame( serv => \$packed );

				# Bug 14400: make sure we do not later accidentally reattach a returning client
				# to a sync-group that is no longer current.
				$prefs->client($_)->remove('syncgroupid');

				# Give player time to disconnect
				Slim::Utils::Timers::setTimer($_, time() + 3,
					sub { shift->execute([ 'client', 'forget' ]); }
				);
			} else {
				$log->warn('Cannot switch player to new server as player not capable: ', $_->id());
			}
		}
	}

	$request->setStatusDone();
}

sub clientForgetCommand {
	my $request = shift;

	# check this is the correct command. Syntax approved by Dean himself!
	if ($request->isNotCommand([['client'], ['forget']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	# Bug 6508
	# Can have a timing race with client reconnecting before this command get executed
	if ($client->connected()) {
		main::INFOLOG && $log->info($client->id . ': not forgetting as connected again');
		return;
	}

	$client->controller()->playerInactive($client);

	$client->forgetClient();

	$request->setStatusDone();
}


sub debugCommand {
	my $request = shift;

	# check this is the correct command. Syntax approved by Dean himself!
	if ($request->isNotCommand([['debug']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $category = $request->getParam('_debugflag');
	my $newValue = $request->getParam('_newvalue');

	if ( !defined $category || !Slim::Utils::Log->isValidCategory($category) ) {

		$request->setStatusBadParams();
		return;
	}

	my $ret = Slim::Utils::Log->setLogLevelForCategory($category, $newValue);

	if ($ret == 0) {

		$request->setStatusBadParams();
		return;
	}

	# If the above setLogLevelForCategory has returned true, we need to reinitialize.
	if ($ret == 1) {

		Slim::Utils::Log->reInit;
	}

	$request->setStatusDone();
}

# disconnect a player from a remote server and connect to us
# this is done by doing a "connect" call to the remote server
sub disconnectCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['disconnect']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $remoteClient = $request->getParam('_playerid');
	my $server       = $request->getParam('_from');

	if (! ($remoteClient && $server)) {
		$request->setStatusBadParams();
		return;
	}

	$server = Slim::Networking::Discovery::Server::getWebHostAddress($server);

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {},
		sub { $log->error("Problem disconnecting client $remoteClient from $server: " . shift->error); },
		{ timeout => 10 }
	);

	my $postdata = to_json({
		id     => 1,
		method => 'slim.request',
		params => [ $remoteClient, ['connect', Slim::Utils::Network::hostAddr()] ]
	});

	main::DEBUGLOG && $log->debug("Sending connect request to $server: $postdata");

	$http->get( $server . 'jsonrpc.js', $postdata);

	$request->setStatusDone();
}


sub displayCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['display']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client   = $request->client();
	my $line1    = $request->getParam('_line1');
	my $line2    = $request->getParam('_line2');
	my $duration = $request->getParam('_duration');
	my $p4       = $request->getParam('_p4');

	if (!defined $line1) {
		$request->setStatusBadParams();
		return;
	}

	Slim::Buttons::ScreenSaver::wakeup($client);

	$client->showBriefly({
		'line' => [ $line1, $line2 ],
	}, $duration, $p4);

	$request->setStatusDone();
}

sub irCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['ir']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client      = $request->client();
	my $irCodeBytes = $request->getParam('_ircode');
	my $irTime      = $request->getParam('_time');

	if (!defined $irCodeBytes || !defined $irTime ) {
		$request->setStatusBadParams();
		return;
	}

	Slim::Hardware::IR::processIR($client, $irCodeBytes, $irTime);

	$request->setStatusDone();
}


sub irenableCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['irenable']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client    = $request->client();
	my $newenable = $request->getParam('_newvalue');

	# handle toggle
	if (!defined $newenable) {

		$newenable = $client->irenable() ? 0 : 1;
	}

	$client->irenable($newenable);

	$request->setStatusDone();
}

sub loggingCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['logging']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $group = uc( $request->getParam('group') );

	if ($group && Slim::Utils::Log->logLevels($group)) {
		Slim::Utils::Log->setLogGroup($group, $request->getParam('persist'));
	}
	else {
		$request->setStatusBadParams();
		return;
	}

	$request->setStatusDone();
}

sub mixerCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['mixer'], ['volume', 'muting', 'treble', 'bass', 'pitch', 'stereoxl']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client   = $request->client();
	my $entity   = $request->getRequest(1);
	my $newvalue = $request->getParam('_newvalue');

	my $sequenceNumber = $request->getParam('seq_no');
	if (defined $sequenceNumber) {
		$client->sequenceNumber($sequenceNumber);
	}

	my $controllerSequenceId = $request->getParam('controllerSequenceId');
	if (defined $controllerSequenceId) {
		$client->controllerSequenceId($controllerSequenceId);
		$client->controllerSequenceNumber($request->getParam('controllerSequenceNumber'));
	}

	my @buddies;

	# if we're sync'd, get our buddies
	if ($client->isSynced()) {
		@buddies = $client->syncedWith();
	}

	if ($entity eq 'muting') {

		my $curmute = $prefs->client($client)->get('mute');

		if ( !defined $newvalue || $newvalue eq 'toggle' ) { # toggle
			$newvalue = !$curmute;
		}

		if ($newvalue != $curmute) {
			my $vol = $client->volume();
			my $fade;

			if ($newvalue == 0) {

				# need to un-mute volume
				main::INFOLOG && $log->info("Unmuting, volume is [$vol]");

				$prefs->client($client)->set('mute', 0);
				$fade = 0.3125;

			} else {

				# need to mute volume
				main::INFOLOG && $log->info("Muting, volume is [$vol]");

				$prefs->client($client)->set('mute', 1);
				$fade = -0.3125;
			}

			$client->fade_volume($fade, \&_mixer_mute, [$client]);

			# Bug 18165: do not sync volume if client's volume itself is not synced
			if ($prefs->client($client)->get('syncVolume')) {

				for my $eachclient (@buddies) {

					if ($prefs->client($eachclient)->get('syncVolume')) {

						$eachclient->fade_volume($fade, \&_mixer_mute, [$eachclient]);
					}
				}
			}
		}

	} else {

		my $newval;
		my $oldval = $prefs->client($client)->get($entity);

		# if the player is muted and the volume changed, unmute first
		# we're resetting the volume to 0 to mimick the IR behaviour in case of relative changes
		if ($entity eq 'volume' && $prefs->client($client)->get('mute')) {
			$prefs->client($client)->set('mute', 0);
			$oldval = 0;
		}

		if ($newvalue =~ /^[\+\-]/) {
			$newval = $oldval + $newvalue;
		} else {
			$newval = $newvalue;
		}

		if ($entity eq 'volume' && defined $client->tempVolume && $client->tempVolume == 0 && $oldval > 0) {
			# only set pref as volume is temporarily set to 0
			$prefs->client($client)->set('volume', $newval) if ($newval <= $client->maxVolume);
		} else {
			# change current setting - this will also set the pref
			$newval = $client->$entity($newval);
		}

		# Bug 18165: do not sync volume if client's volume itself is not synced
		if ($prefs->client($client)->get('syncVolume')) {
			for my $eachclient (@buddies) {
				if ($prefs->client($eachclient)->get('syncVolume')) {
					$prefs->client($eachclient)->set($entity, $newval);
					$eachclient->$entity($newval);
					$eachclient->mixerDisplay('volume') if $entity eq 'volume';
				}
			}
		}
	}

	if (defined $controllerSequenceId) {
		$client->controllerSequenceId(undef);
		$client->controllerSequenceNumber(undef);
	}

	$request->setStatusDone();
}


sub nameCommand {
	my $request = shift;

	if ($request->isNotCommand([['name']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();
	my $newValue = $request->getParam('_newvalue');

	if (!defined $newValue || !defined $client) {
		$request->setStatusBadParams();
		return;
	}

	if ($newValue ne "0") {
		main::DEBUGLOG && $log->debug("PLAYERNAMECHANGE: " . $newValue);
		$prefs->client($client)->set('playername', $newValue);
		# refresh Jive menu
		Slim::Control::Jive::playerSettingsMenu($client);
		Slim::Control::Jive::playerPower($client);
	}

	$request->setStatusDone();
}


sub playcontrolCommand {
	my $request = shift;

	# check this is the correct command.
	# "mode" is deprecated
	if ($request->isNotCommand([['play', 'stop', 'pause']]) &&
		$request->isNotCommand([['mode'], ['play', 'pause', 'stop']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();
	my $cmd    = $request->getRequest(0);
	my $param  = $request->getRequest(1);
	my $newvalue = $request->getParam('_newvalue');
	my $fadeIn = $request->getParam('_fadein');
	my $suppressShowBriefly = $request->getParam('_suppressShowBriefly');

	# which state are we in?
	my $curmode = Slim::Player::Source::playmode($client);

	# which state do we want to go to?
	my $wantmode = $cmd;

	# the "mode" command is deprecated, please do not use or fix
	if ($cmd eq 'mode') {

		# we want to go to $param if the command is mode
		$wantmode = $param;
		# and for pause we want 1
		$newvalue = 1;
	}

	if ($cmd eq 'pause') {

		# pause 1, pause 0 and pause (toggle) are all supported, figure out which
		# one we want...
		if (defined $newvalue) {
			$wantmode = $newvalue ? 'pause' : 'play';
		} else {
			# Toggle, or start upon a pause command if player is currently in stop mode
			$wantmode = ($curmode eq 'pause' || $curmode eq 'stop') ? 'play' : 'pause';
		}
	}
	# Adjust for resume: if we're paused and asked to play, we resume
	$wantmode = 'resume' if ($curmode eq 'pause' && $wantmode eq 'play');

	# Adjust for pause: can only do it from play
	if ($wantmode eq 'pause') {

		# default to doing nothing...
		$wantmode = $curmode;

		# pause only from play
		$wantmode = 'pause' if $curmode eq 'play';
	}

	# do we need to do anything?
	if ($curmode ne $wantmode) {

		if ( $wantmode eq 'play' ) {
			# Bug 6813, 'play' from CLI needs to work the same as IR play button, by going
			# through playlist jump - this will include a showBriefly to give feedback
			my $index = Slim::Player::Source::playingSongIndex($client);

			$client->execute(['playlist', 'jump', $index, $fadeIn]);
		}
		else {
			# set new playmode
			Slim::Player::Source::playmode($client, $wantmode, undef, undef, $fadeIn);

			# give user feedback of new mode and current song
			if ($client->isPlayer()) {
				my $parts = $client->currentSongLines({ suppressDisplay => Slim::Buttons::Common::suppressStatus($client) });
				if ($suppressShowBriefly) {
					$parts->{jive} = undef;
				}
				$client->showBriefly($parts) if $parts;
			}
		}
	}

	$request->setStatusDone();
}


sub playlistClearCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['clear']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	Slim::Player::Playlist::stopAndClear($client);

	# called by currentPlaylistUpdateTime below
	# $client->currentPlaylistChangeTime(Time::HiRes::time());

	$client->currentPlaylistUpdateTime(Time::HiRes::time());

	# The above changes the playlist but I am not sure this is ever
	# executed, or even if it should be
	Slim::Player::Playlist::refreshPlaylist($client) if $client->currentPlaylistModified();

	$request->setStatusDone();
}


sub playlistDeleteCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['delete']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();
	my $index  = $request->getParam('_index');;

	if (!defined $index) {
		$request->setStatusBadParams();
		return;
	}

	Slim::Player::Playlist::removeTrack($client, $index);

	$client->currentPlaylistModified(1);
	#$client->currentPlaylistChangeTime(Time::HiRes::time());
	$client->currentPlaylistUpdateTime(Time::HiRes::time());
	Slim::Player::Playlist::refreshPlaylist($client);

	$request->setStatusDone();
}


sub playlistDeleteitemCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['deleteitem']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();
	my $item   = $request->getParam('_item');;

	if (!$item) {
		$request->setStatusBadParams();
		return;
	}

	# This used to update $p2; anybody depending on this behaviour needs
	# to be changed to used the returned result (commented below)
	my $contents = [];
	my $absitem  = blessed($item) ? $item->url : $item;

	if (!Slim::Music::Info::isList($absitem)) {

		Slim::Player::Playlist::removeMultipleTracks($client, [$absitem]);

	} elsif (Slim::Music::Info::isDir($absitem)) {
		require Slim::Utils::Scanner;

		Slim::Utils::Scanner->scanPathOrURL({
			'url'      => Slim::Utils::Misc::pathFromFileURL($absitem),
			'listRef'  => \@{$contents},
			'client'   => $client,
			'callback' => sub {
				my $foundItems = shift;

				Slim::Player::Playlist::removeMultipleTracks($client, $foundItems);
			},
		});

	} else {

		my $playlist = Slim::Schema->objectForUrl({ 'url' => $item, playlist => 1 });

		if ($playlist) {
			$contents = [ map { $_->url } $playlist->tracks ];
		}

		if (!scalar @$contents) {

			my $fh = undef;

			if (!open($fh, Slim::Utils::Misc::pathFromFileURL($absitem))) {

				logError("Couldn't open playlist file $absitem : $!");

				$fh = undef;

			} else {

				$contents = [Slim::Formats::Playlists->parseList($absitem, $fh, dirname($absitem))];
			}
		}

		if (scalar @$contents) {
			Slim::Player::Playlist::removeMultipleTracks($client, $contents);
		}
	}

	$contents = [];

	$client->currentPlaylistModified(1);
	#$client->currentPlaylistChangeTime(Time::HiRes::time());
	$client->currentPlaylistUpdateTime(Time::HiRes::time());
	Slim::Player::Playlist::refreshPlaylist($client);

	$request->setStatusDone();
}


sub playlistJumpCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['jump', 'index']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();
	my $index  = $request->getParam('_index');
	my $fadeIn = $request->getParam('_fadein');
	my $noplay = $request->getParam('_noplay');
	my $seekdata = $request->getParam('_seekdata');

	my $songcount = Slim::Player::Playlist::count($client) || return;

	my $newIndex = 0;
	my $isStopped = $client->isStopped();

	if (!$client->power()) {
		$client->execute([ 'power', 1, 1 ]);
	}

	my $showStatus = sub {
		my $jiveIconStyle = shift || undef;
		if ($client->isPlayer()) {
			my $parts = $client->currentSongLines({
					suppressDisplay => Slim::Buttons::Common::suppressStatus($client),
					jiveIconStyle => $jiveIconStyle,
				});

			# awy: We used to set $parts->{'jive'}->{'duration'} = 10000 here in order to
			# ensure that the new track title is pushed to the first line of the display
			# and stays there until a new playerStatus arrives. This can take quite a
			# long time under some circumstances, such as with slow servers. However,
			# setting the delay here affected both the duration of the new title on the
			# display and that of the the Play pop-up icon if the command was invoked via IR.
			# Having the popup hang around for 10s can be irritating (bug 17758). Given that
			# the player has control of title change itself, it can set a long duration
			# on just that element and use the default show-briefly duration for the popup.

			$client->showBriefly($parts, { duration => 2 }) if $parts;
			Slim::Buttons::Common::syncPeriodicUpdates($client, Time::HiRes::time() + 0.1);
		}
	};

	# Is this a relative jump, etc.
	if ( defined $index && $index =~ /[+-]/ ) {

		if (!$isStopped) {

			if ( ($songcount == 1 && $index eq '-1') || $index eq '+0' ) {
				# User is trying to restart the current track
				$client->controller()->jumpToTime(0, 1);
				$showStatus->('rew');
				$request->setStatusDone();
				return;
			} elsif ($index eq '+1') {
				# User is trying to skip to the next track
				$client->controller()->skip();
				$showStatus->('fwd');
				$request->setStatusDone();
				return;
			}

		}

		$newIndex = Slim::Player::Source::playingSongIndex($client) + $index;
		main::INFOLOG && $log->info("Jumping by $index");

		# Handle skip in repeat mode
		if ( $newIndex >= $songcount ) {
			# play the next song and start over if necessary
			if (Slim::Player::Playlist::shuffle($client) &&
				Slim::Player::Playlist::repeat($client) == 2 &&
				$prefs->get('reshuffleOnRepeat')) {

				Slim::Player::Playlist::reshuffle($client, 1);
			}
		}

	} else {
		$newIndex = $index if defined $index;
		main::INFOLOG && $log->info("Jumping to $newIndex");
	}

	# Check for wrap-around
	if ($newIndex >= $songcount) {
		$newIndex %=  $songcount;
	} elsif ($newIndex < 0) {
		$newIndex =  ($newIndex + $songcount) % $songcount;
	}

	if ($noplay && $isStopped) {
		$client->controller()->resetSongqueue($newIndex);
	} else {
		main::INFOLOG && $log->info("playing $newIndex");
		$client->controller()->play($newIndex, $seekdata, undef, $fadeIn);
	}

	# Does the above change the playlist?
	Slim::Player::Playlist::refreshPlaylist($client) if $client->currentPlaylistModified();

	# if we're jumping +1/-1 in the index let squeezeplay know this showBriefly is to be styled accordingly
	my $jiveIconStyle = undef;
	if ($index && $index eq '-1') {
		$jiveIconStyle = 'rew';
	} elsif ($index && $index eq '+1')  {
		$jiveIconStyle = 'fwd';
	}
	$showStatus->($jiveIconStyle);

	$request->setStatusDone();
}

sub playlistMoveCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['move']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client     = $request->client();
	my $fromindex  = $request->getParam('_fromindex');;
	my $toindex    = $request->getParam('_toindex');;

	if (!defined $fromindex || !defined $toindex) {
		$request->setStatusBadParams();
		return;
	}

	Slim::Player::Playlist::moveSong($client, $fromindex, $toindex);
	$client->currentPlaylistModified(1);
	#$client->currentPlaylistChangeTime(Time::HiRes::time());
	$client->currentPlaylistUpdateTime(Time::HiRes::time());

	Slim::Player::Playlist::refreshPlaylist($client);

	$request->setStatusDone();
}


sub playlistRepeatCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['repeat']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client   = $request->client();
	my $newvalue = $request->getParam('_newvalue');

	if (!defined $newvalue) {
		# original code: (Slim::Player::Playlist::repeat($client) + 1) % 3
		$newvalue = (1,2,0)[Slim::Player::Playlist::repeat($client)];
	}

	Slim::Player::Playlist::repeat($client, $newvalue);

	$request->setStatusDone();
}


sub playlistSaveCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['save']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# can't do much without playlistdir!
	if (!Slim::Utils::Misc::getPlaylistDir()) {
		$request->setStatusBadConfig();
		return;
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('writeError', 1);
		$request->setStatusDone();
		return;
	}

	# get the parameters
	my $client = $request->client();
	my $title  = $request->getParam('_title');
	my $silent = $request->getParam('silent') || 0;
	my $titlesort = Slim::Utils::Text::ignoreCaseArticles($title);

	$title = Slim::Utils::Misc::cleanupFilename($title);

	my $playlistObj = Slim::Schema->updateOrCreate({

		'url' => Slim::Utils::Misc::fileURLFromPath(
			catfile( Slim::Utils::Misc::getPlaylistDir(), Slim::Utils::Unicode::encode_locale($title) . '.m3u')
		),
		'playlist' => 1,
		'attributes' => {
			'TITLE' => $title,
			'CT'    => 'ssp',
		},
	});

	my $annotatedList = [];

	if ($prefs->get('saveShuffled')) {

		for my $shuffleitem (@{Slim::Player::Playlist::shuffleList($client)}) {
			push @$annotatedList, Slim::Player::Playlist::track($client, $shuffleitem, 0, 0);
		}

	} else {

		$annotatedList = Slim::Player::Playlist::playList($client);
	}

	$playlistObj->set_column('titlesort', $titlesort);
	$playlistObj->set_column('titlesearch', $titlesort);
	$playlistObj->setTracks($annotatedList);
	$playlistObj->update;

	Slim::Schema->forceCommit;

	if (!defined Slim::Player::Playlist::scheduleWriteOfPlaylist($client, $playlistObj)) {
		$request->addResult('writeError', 1);
	}

	$request->addResult('__playlist_id', $playlistObj->id);

	if ($client && $playlistObj->title ne Slim::Utils::Strings::string('UNTITLED')) {
		$client->currentPlaylist($playlistObj);
		$client->currentPlaylistUpdateTime(Time::HiRes::time());
		$client->currentPlaylistModified(0);
	}

	if ( ! $silent ) {
		$client->showBriefly({
			'jive' => {
				'type'    => 'popupplay',
				'text'    => [ $client->string('SAVED_THIS_PLAYLIST_AS', $title) ],
			}
		});
	}

	$request->setStatusDone();
}

sub playlistShuffleCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['shuffle']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client   = $request->client();
	my $newvalue = $request->getParam('_newvalue');

	if (!defined $newvalue) {
		$newvalue = (1,2,0)[Slim::Player::Playlist::shuffle($client)];
	}

	Slim::Player::Playlist::shuffle($client, $newvalue);
	Slim::Player::Playlist::reshuffle($client);
	#$client->currentPlaylistChangeTime(Time::HiRes::time());
	$client->currentPlaylistUpdateTime(Time::HiRes::time());

	# Does the above change the playlist?
	Slim::Player::Playlist::refreshPlaylist($client) if $client->currentPlaylistModified();

	$request->setStatusDone();
}


sub playlistXalbumCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['playalbum', 'loadalbum', 'addalbum', 'insertalbum', 'deletealbum']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client   = $request->client();
	my $cmd      = $request->getRequest(1);
	my $genre    = $request->getParam('_genre'); #p2
	my $artist   = $request->getParam('_artist');#p3
	my $album    = $request->getParam('_album'); #p4
	my $title    = $request->getParam('_title'); #p5

	# Pass to parseSearchTerms
	my $find     = {};

	if (specified($genre) && $genre ne '') {

		$find->{'genre.name'} = { like => _playlistXalbum_singletonRef($genre) };
	}

	if (specified($artist) && $artist ne '') {

		$find->{'contributor.name'} = { like => _playlistXalbum_singletonRef($artist) };
	}

	if (specified($album) && $album ne '') {

		$find->{'album.title'} = { like => _playlistXalbum_singletonRef($album) };
	}

	if (specified($title) && $title ne '') {

		$find->{'me.title'} = { like => _playlistXalbum_singletonRef($title) };
	}

	my @results = _playlistXtracksCommand_parseSearchTerms($client, $find, $cmd);

	$cmd =~ s/album/tracks/;

	Slim::Control::Request::executeRequest($client, ['playlist', $cmd, 'listRef', \@results]);

	$request->setStatusDone();
}


sub playlistPreviewCommand {
	my $request = shift;
	# check this is the correct command.
	if ( $request->isNotCommand( [ ['playlist'], ['preview' ] ]) ) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client   = $request->client();
	my $cmd      = $request->getParam('cmd');
	my $url      = $request->getParam('url');
	my $title    = $request->getParam('title') || '';
	my $fadeIn   = $request->getParam('fadein') ? $request->getParam('fadein') : undef;

	# if we have a cmd of 'stop', load the most recent playlist (which will clear the preview)
	if ($cmd eq 'stop') {
		# stop and clear the current tone
		Slim::Player::Playlist::stopAndClear($client);

		my $filename = _getPreviewPlaylistName($client);
		main::INFOLOG && $log->info("loading ", $filename, " to resume previous playlist");

		# load mostrecent.m3u and jump to the previously playing track, but don't play
		$client->execute( [ 'playlist', 'resume', $filename, '', 'noplay:1', 'wipePlaylist:1' ]);

	} else {

		# if we're not stopping, we're previewing. first check for correct params
		if ( ! defined($url) ) {
			$request->setStatusBadDispatch();
			return;
		}

		my $filename = _getPreviewPlaylistName($client);
		main::INFOLOG && $log->info("saving current playlist as ", $filename);
                $client->execute( ['playlist', 'save', $filename, 'silent:1' ] );

		main::INFOLOG && $log->info("queuing up ", $title, " for preview");
		$client->execute( ['playlist', 'play', $url, $title, $fadeIn ] );

	}

	$request->setStatusDone();

}

sub _getPreviewPlaylistName {
	my $client = shift;
	my $filename = "tempplaylist_" . $client->id();
	$filename =~ s/://g;
	return $filename;
}

sub playlistXitemCommand {
	my $request = shift;
	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['add', 'append', 'insert', 'insertlist', 'load', 'play', 'resume']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client   = $request->client();
	my $cmd      = $request->getRequest(1); #p1
	my $item     = $request->getParam('_item'); #p2
	my $title    = $request->getParam('_title') || ''; #p3
	my $fadeIn   = $cmd eq 'play' ? $request->getParam('_fadein') : undef;
	my $noplay       = $request->getParam('noplay') || 0; # optional tagged param, used for resuming playlist after preview
	my $wipePlaylist = $request->getParam('wipePlaylist') || 0; #optional tagged param, used for removing playlist after resume

	if (!defined $item) {
		$request->setStatusBadParams();
		return;
	}

	$title = Slim::Utils::Unicode::utf8decode($title) if $title;

	main::INFOLOG && $log->info("cmd: $cmd, item: $item, title: $title, fadeIn: ", ($fadeIn ? $fadeIn : 'undef'));

	my $jumpToIndex = $request->getParam('play_index'); # This should be undef (by default) - see bug 2085
	my $results;

	# If we're playing a list of URLs (from XMLBrowser), only work on the first item
	my $list;
	if ( ref $item eq 'ARRAY' ) {

		# If in shuffle mode, we need to shuffle the list of items as
		# soon as we get it
		if ( Slim::Player::Playlist::shuffle($client) == 1 ) {
			Slim::Player::Playlist::fischer_yates_shuffle($item);
		}

		$list = $item;
		$item = shift @{$item};
	}

	my $url  = blessed($item) ? $item->url : $item;

	# Strip off leading and trailing whitespace. PEBKAC
	$url =~ s/^\s*//;
	$url =~ s/\s*$//;

	main::INFOLOG && $log->info("url: $url");

	my $path = $url;

	# Set title if supplied
	if ( $title ) {
		Slim::Music::Info::setTitle( $url, $title );
		Slim::Music::Info::setCurrentTitle( $url, $title );
	}

	# check whether url is potentially for some sort of db entry, if so pass to playlistXtracksCommand
	# But not for or local file:// URLs,  and this may mean
	# rescanning items already in the database but still allows playlist and other favorites to be played

	# hardcoding these protocols isn't the best way to do this. We should be using the protocol handler's explodePlaylist call.
	if ($path =~ /^db:|^itunesplaylist:|^musicipplaylist:/) {
		if (my @tracks = _playlistXtracksCommand_parseDbItem($client, $path)) {
			$client->execute(['playlist', $cmd . 'tracks' , 'listRef', \@tracks, $fadeIn]);
			$request->setStatusDone();
			return;
		}
	}

	# if we have a single item, we might need to expand it to some list (eg. Spotify Album -> track list)
	my $handler = Slim::Player::ProtocolHandlers->handlerForURL($path) unless $list;

	if ( $handler && $handler->can('explodePlaylist') ) {
		$handler->explodePlaylist($client, $path, sub {
			my $tracks = shift;
			# transform opml list into url array if needed
			if (ref $tracks eq 'HASH') {
				$tracks = [ map {
					$_->{play} || $_->{url}
				} @{$tracks->{items}} ];
			}
			$client->execute(['playlist', $cmd . 'tracks' , 'listRef', $tracks, $fadeIn]);
			$request->setStatusDone();
		});

		return;
	}

	# correct the path
	# this only seems to be useful for playlists?
	if (!Slim::Music::Info::isRemoteURL($path) && !-e $path && !(Slim::Music::Info::isPlaylistURL($path))) {

		my $easypath = catfile(Slim::Utils::Misc::getPlaylistDir(), basename($url) . ".m3u");

		if (-e $easypath) {

			$path = $easypath;

		} else {

			$easypath = catfile(Slim::Utils::Misc::getPlaylistDir(), basename($url) . ".pls");

			if (-e $easypath) {
				$path = $easypath;
			}
		}
	}

	# Un-escape URI that have been escaped again.
	if (Slim::Music::Info::isRemoteURL($path) && $path =~ /%3A%2F%2F/) {

		$path = Slim::Utils::Misc::unescape($path);
	}

	main::INFOLOG && $log->info("path: $path");

	# bug 14760 - just continue where we were if what we are about to play is the
	# same as the single thing we are already playing
	if ( $cmd =~ /^(play|load)$/
		&& Slim::Player::Playlist::count($client) == 1
		&& $client->playingSong()
		&& $path eq $client->playingSong()->track()->url()
		&& !$noplay )
	{
		# Bug 16154: use more-precise control measures
		# so that we only leave it playing if fully in Playing state already.
		if ( $client->isPaused() ) {
			Slim::Player::Source::playmode($client, 'resume', undef, undef, $fadeIn);
		} elsif ( !$client->isPlaying('really') ) {
			Slim::Player::Source::playmode($client, 'play', undef, undef, $fadeIn);
		}

		# XXX: this should not be calling a request callback directly!
		# It should be handled by $request->setStatusDone
		if ( my $callbackf = $request->callbackFunction ) {
			if ( my $callbackargs = $request->callbackArguments ) {
				$callbackf->( @{$callbackargs} );
			}
			else {
				$callbackf->( $request );
			}
		}

		playlistXitemCommand_done($client, $request, $path);

		main::DEBUGLOG && $log->debug("done.");

		return;
	}

	my $fixedPath = Slim::Utils::Misc::fixPath($path);

	if ($cmd =~ /^(play|load|resume)$/) {

		Slim::Player::Playlist::stopAndClear($client);

		$client->currentPlaylist( $fixedPath );

		if ( main::INFOLOG && $log->is_info ) {
			$log->info("currentPlaylist:" .  $fixedPath );
		}

		$client->currentPlaylistModified(0);

	} elsif ($cmd =~ /^(add|append)$/) {

		$client->currentPlaylist( $fixedPath );
		$client->currentPlaylistModified(1);

		if ( main::INFOLOG && $log->is_info ) {
			$log->info("currentPlaylist:" .  $fixedPath );
		}

	} else {

		$client->currentPlaylistModified(1);
	}

	# is this a track referenced from a cue sheet?
	my $isReferenced;

	if (!Slim::Music::Info::isRemoteURL( $fixedPath ) && Slim::Music::Info::isFileURL( $fixedPath ) ) {

		$path = Slim::Utils::Misc::pathFromFileURL($fixedPath);

		# referenced tracks come with a #start-end postfix in the url
		$isReferenced = ($fixedPath =~ /#\d+.*\d+$/ && $path !~ /#\d+.*\d+$/) ? 1 : 0;

		main::INFOLOG && $log->info("path: $path");
	}

	if ($cmd =~ /^(play|load)$/) {

		$jumpToIndex = 0 if !defined $jumpToIndex;

	} elsif ($cmd eq "resume" && Slim::Music::Info::isM3U($path)) {

		$jumpToIndex = Slim::Formats::Playlists::M3U->readCurTrackForM3U($path);
	}

	if ( main::INFOLOG && $log->is_info ) {
		$log->info(sprintf("jumpToIndex: %s", (defined $jumpToIndex ? $jumpToIndex : 'undef')));
	}

	if ($cmd =~ /^(insert|insertlist)$/) {

		my @dirItems     = ();

		require Slim::Utils::Scanner;

		Slim::Utils::Scanner->scanPathOrURL({
			'url'      => $path,
			'listRef'  => \@dirItems,
			'client'   => $client,
			'callback' => sub {
				my $foundItems = shift;

				my $added = Slim::Player::Playlist::addTracks($client, $foundItems, 1);

				_insert_done(
					$client,
					$added,
					$request->callbackFunction,
					$request->callbackArguments,
				);

				playlistXitemCommand_done( $client, $request, $path );
			},
		});
		if ( $cmd eq 'insert' && Slim::Music::Info::isRemoteURL($path) && !Slim::Music::Info::isDigitalInput($path) && !Slim::Music::Info::isLineIn($path) ) {

			my $insert = Slim::Music::Info::title($path) || $path;
			my $msg = $client->string('JIVE_POPUP_ADDING_TO_PLAY_NEXT', $insert);
			my @line = split("\n", $msg);
			$client->showBriefly({
					'line' => [ @line ],
					'jive' => { 'type' => 'popupplay', text => [ $msg ] },
				});
		}

	} else {

		# Display some feedback for the player on remote URLs
		# XXX - why only remote URLs?
		if ( $cmd eq 'add' && Slim::Music::Info::isRemoteURL($path) && !Slim::Music::Info::isDigitalInput($path) && !Slim::Music::Info::isLineIn($path) ) {

			my $insert = Slim::Music::Info::title($path) || $path;
			$client->showBriefly( {
				line => [
					$client->string('ADDING_TO_PLAYLIST'),
					$insert,
				],
				jive => {
					type => 'popupplay',
					text => [
						$client->string('JIVE_POPUP_ADDING_TO_PLAYLIST', $insert)
					],
				},
			} );
		}

		require Slim::Utils::Scanner;

		Slim::Utils::Scanner->scanPathOrURL({
			'url'      => $isReferenced ? $url : $path,
			'listRef'  => Slim::Player::Playlist::playList($client),
			'client'   => $client,
			'cmd'      => $cmd,
			'callback' => sub {
				my ( $foundItems, $error ) = @_;

				# tracks referenced from cue sheet would not be found due to their special content type - add the raw URL back in
				if ( ref $foundItems eq 'ARRAY' && !scalar @$foundItems && $isReferenced ) {
					push @$foundItems, $url;
				}

				# If we are playing a list of URLs, add the other items now
				my $noShuffle = 0;
				if ( ref $list eq 'ARRAY' ) {
					push @{$foundItems}, @{$list};

					# XXX - we DO need to shuffle, as otherwise the client's shufflelist will not know about the newly added items!
					#$noShuffle = 1;
				}

				Slim::Player::Playlist::addTracks($client, $foundItems, 0);

				_playlistXitem_load_done(
					$client,
					$jumpToIndex,
					$request,
					Slim::Player::Playlist::count($client),
					Slim::Utils::Misc::fixPath($path),
					$error,
					$noShuffle,
					$fadeIn,
					$noplay,
					$wipePlaylist,
				);


				playlistXitemCommand_done( $client, $request, $path );
			},
		});

	}

	if (!$request->isStatusDone()) {
		$request->setStatusProcessing();
	}

	main::DEBUGLOG && $log->debug("done.");
}

# Called after insert/load async callbacks are finished
sub playlistXitemCommand_done {
	my ( $client, $request, $path ) = @_;

	# The callback, if any, will be called by _load/_insert_done, so
	# don't call it now
	# Hmm, in fact the request is not done until load/insert is called.
	# addToList is asynchronous. load/insert should call request done...
	$request->callbackEnabled(0);

	# Update the parameter item with the correct path
	# Not sure anyone depends on this behaviour...
	$request->addParam('_item', $path);

	$client->currentPlaylistUpdateTime(Time::HiRes::time());

	Slim::Player::Playlist::refreshPlaylist($client) if $client->currentPlaylistModified();

	$request->setStatusDone();
}

sub playlistXtracksCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['playtracks', 'loadtracks', 'addtracks', 'inserttracks', 'deletetracks']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client      = $request->client();
	my $cmd         = $request->getRequest(1); #p1
	my $what        = $request->getParam('_what'); #p2
	my $listref     = $request->getParam('_listref');#p3
	my $fadeIn      = $request->getParam('_fadein');#p4
	my $jumpToIndex = $request->getParam('_index');#p5, by default undef - see bug 2085

	if (!defined $what) {
		$request->setStatusBadParams();
		return;
	}

	my $load   = ($cmd eq 'loadtracks' || $cmd eq 'playtracks');
	my $insert = ($cmd eq 'inserttracks');
	my $add    = ($cmd eq 'addtracks');
	my $delete = ($cmd eq 'deletetracks');

	# if loading, start by clearing it all...
	if ($load) {
		Slim::Player::Playlist::stopAndClear($client);
	}

	# parse the param
	my @tracks = ();

	if ($what =~ /urllist/i) {
		@tracks = _playlistXtracksCommand_constructTrackList($client, $what, $listref);

	} elsif ($what =~ /listRef/i) {
		@tracks = _playlistXtracksCommand_parseListRef($client, $what, $listref);

	} elsif ($what =~ /searchRef/i) {

		@tracks = _playlistXtracksCommand_parseSearchRef($client, $what, $listref);

	} else {

		@tracks = _playlistXtracksCommand_parseSearchTerms($client, $what, $cmd);
	}

	if ( scalar @tracks && $what =~ /track\.titlesearch|contributor\.namesearch|genre\.id|track\.year/i ) {
		if ($prefs->get('useBalancedShuffle')) {
			my $categoryMethod = 'artistName';
			my $categoryRemoteItem = 'artist';

			if ($what =~ /contributor\.namesearch/i) {
				$categoryMethod = 'albumname';
				$categoryRemoteItem = 'album';
			}

			my $sortList = Slim::Player::Playlist::balancedShuffle([ map {
				my $track = $tracks[$_];
				my $category = $track->$categoryMethod if ref $track && $track->can($categoryMethod);

				if (!$categoryMethod) {
					my $url = ref $track ? $track->url : $track;
					my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

					if ( $handler && $handler->can('getMetadataFor') && (my $meta = $handler->getMetadataFor($client, $url)) ) {
						$category = $meta->{$categoryRemoteItem};
					}
				}

				[$_, $category || ''];
			} 0 .. $#tracks ], 'alpha');

			@tracks = @tracks[@$sortList];
		}
		else {
			Slim::Player::Playlist::fischer_yates_shuffle(\@tracks);
		}
	};

	my $size;

	# add or remove the found songs
	if ($load || $add || $insert) {
		$size = Slim::Player::Playlist::addTracks($client, \@tracks, $insert);
	}

	if ($insert) {
		_insert_done($client, $size);
		$request->addResult(index => (Slim::Player::Source::streamingSongIndex($client)+1));
	}

	if ($delete) {
		Slim::Player::Playlist::removeMultipleTracks($client, \@tracks);
	}

	if ($load || $add) {
		Slim::Player::Playlist::reshuffle($client, $load ? 1 : undef);
		$request->addResult(index => (Slim::Player::Playlist::count($client) - $size));	# does not mean much if shuffled
	}

	if ($load) {
		# The user may have stopped in the middle of a
		# saved playlist - resume if we can. Bug 1582
		my $playlistObj = $client->currentPlaylist();

		if ($playlistObj && ref($playlistObj) && $playlistObj->content_type =~ /^(?:ssp|m3u)$/) {

			if (!defined $jumpToIndex && !Slim::Player::Playlist::shuffle($client)) {
				$jumpToIndex = Slim::Formats::Playlists::M3U->readCurTrackForM3U( $client->currentPlaylist->path );
			}

			# And set a callback so that we can
			# update CURTRACK when the song changes.
			Slim::Control::Request::subscribe(\&Slim::Player::Playlist::newSongPlaylistCallback, [['playlist'], ['newsong']]);
		}
		# bug 14662: Playing a specific track while track shuffle is enabled will play another track
		elsif (defined $jumpToIndex && Slim::Player::Playlist::shuffle($client)) {
			my $shuffleList = Slim::Player::Playlist::shuffleList($client);
			for (my $i = 0; $i < scalar @$shuffleList; $i++) {
				if ($shuffleList->[$i] == $jumpToIndex) {
					$jumpToIndex = $i;
					last;
				}
			}
		}

		$client->execute(['playlist', 'jump', $jumpToIndex, $fadeIn]);

		# Reshuffle (again) to get playing song or album at start of list
		Slim::Player::Playlist::reshuffle($client) if $load && defined $jumpToIndex && Slim::Player::Playlist::shuffle($client);

		$client->currentPlaylistModified(0);
	}

	if ($add || $insert || $delete) {
		$client->currentPlaylistModified(1);
	}

	if ($load || $add || $insert || $delete) {
		$client->currentPlaylistUpdateTime(Time::HiRes::time());
	}

	$request->setStatusDone();
}

sub playlistZapCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlist'], ['zap']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');;

	my $zapped   = $client->string('ZAPPED_SONGS');
	my $zapindex = defined $index ? $index : Slim::Player::Source::playingSongIndex($client);
	my $zaptrack  = Slim::Player::Playlist::track($client, $zapindex);

	#  Remove from current playlist
	if (Slim::Player::Playlist::count($client) > 0) {

		# Call ourselves.
		Slim::Control::Request::executeRequest($client, ["playlist", "delete", $zapindex]);
	}

	my $playlistObj = Slim::Schema->updateOrCreate({
		'url'        => Slim::Utils::Misc::fileURLFromPath(
			catfile( Slim::Utils::Misc::getPlaylistDir(), $zapped . '.m3u')
		),
		'playlist'   => 1,

		'attributes' => {
			'TITLE' => $zapped,
			'CT'    => 'ssp',
		},
	});

	$playlistObj->appendTracks([ $zaptrack ]);
	$playlistObj->update;

	Slim::Player::Playlist::scheduleWriteOfPlaylist($client, $playlistObj);

	$client->currentPlaylistModified(1);
	$client->currentPlaylistUpdateTime(Time::HiRes::time());
	Slim::Player::Playlist::refreshPlaylist($client);

	$request->setStatusDone();
}


sub playlistcontrolCommand {
	my $request = shift;

	main::INFOLOG && $log->info("Begin Function");

	# check this is the correct command.
	if ($request->isNotCommand([['playlistcontrol']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client              = $request->client();
	my $cmd                 = $request->getParam('cmd');
	my $jumpIndex           = $request->getParam('play_index');

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', "1");
	}

	if ($request->paramUndefinedOrNotOneOf($cmd, ['load', 'insert', 'add', 'delete'])) {
		$request->setStatusBadParams();
		return;
	}

	my $load   = ($cmd eq 'load');
	my $insert = ($cmd eq 'insert');
	my $add    = ($cmd eq 'add');
	my $delete = ($cmd eq 'delete');


	# shortcut to playlist $cmd url if given a folder_id...
	# the acrobatics it does are too risky to replicate
	if (defined(my $folderId = $request->getParam('folder_id'))) {

		# unfortunately playlist delete is not supported
		if ($delete) {
			$request->setStatusBadParams();
			return;
		}

		my $folder = Slim::Schema->find($folderId < 0 ? 'RemoteTrack' : 'Track', $folderId);

		# make sure it's a folder
		if (!blessed($folder) || !$folder->can('url') || !$folder->can('content_type') || $folder->content_type() ne 'dir') {
			$request->setStatusBadParams();
			return;
		}

		if ( $add || $insert ) {
			my $token;
			if ($add) {
				$token = 'JIVE_POPUP_ADDING_TO_PLAYLIST';
			} elsif ($insert) {
				$token = 'JIVE_POPUP_ADDING_TO_PLAY_NEXT';
			}
			my $string = $client->string($token, $folder->title);
			$client->showBriefly({
				'jive' => {
					'type'    => 'popupplay',
					'text'    => [ $string ],
				}
			});
		}

		Slim::Control::Request::executeRequest(
			$client, ['playlist', $cmd, $folder->url(), ($load && $jumpIndex ? 'play_index:' . $jumpIndex : undef) ]
		);

		$request->addResult('count', 1);
		$request->setStatusDone();
		return;
	}

	# if loading, first stop & clear everything
	if ($load) {
		Slim::Player::Playlist::stopAndClear($client);
	}

	# find the songs
	my @tracks = ();

	# info line and artwork to display if sucessful
	my @info;
	my $artwork;

	# Bug: 2373 - allow the user to specify a playlist name
	my $playlist_id = 0;

	if (defined(my $playlist_name = $request->getParam('playlist_name'))) {

		my $playlistObj = Slim::Schema->single('Playlist', { 'title' => $playlist_name });

		if (blessed($playlistObj)) {

			$playlist_id = $playlistObj->id;
		}
	}

	$playlist_id ||= $request->getParam('playlist_id');

	if ($playlist_id) {

		# Special case...
		my $playlist = Slim::Schema->find('Playlist', $playlist_id);

		if (blessed($playlist) && $playlist->can('tracks')) {

			if ( $add || $load || $insert ) {
				my $token;
				if ($add) {
					$token = 'JIVE_POPUP_ADDING_TO_PLAYLIST';
				} elsif ($insert) {
					$token = 'JIVE_POPUP_ADDING_TO_PLAY_NEXT';
				} else {
					$token = 'JIVE_POPUP_NOW_PLAYING';
				}
				my $string = $client->string($token, $playlist->title);
				$client->showBriefly({
					'jive' => {
						'type'    => 'popupplay',
						'text'    => [ $string ],
					}
				});
			}

			$cmd .= "tracks";

			my $library_id = Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id')) || Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
			my $query = 'playlist.id=' . $playlist_id;
			$query   .= '&library_id=' . $library_id if $library_id;

			Slim::Control::Request::executeRequest(
				$client, ['playlist', $cmd, $query, undef, undef, $jumpIndex]
			);

			$request->addResult( 'count', $playlist->tracks($library_id)->count() );

			$request->setStatusDone();

			return;
		}

	} elsif (defined(my $work_id = $request->getParam('work_id'))) {

		my $criteria = {work => [ '=' => $work_id ]};

		if (defined (my $album_id = $request->getParam('album_id'))) {
			$criteria->{'album'} = [ '=' => $album_id ];
		}

#$log->error("DK request-getParam-grouping=" . Data::Dump::dump($request->getParam('grouping')));
		if (defined (my $grouping = $request->getParam('grouping'))) {
			$criteria->{'grouping'} = [ '=' => $grouping ] if $grouping;
			$criteria->{'grouping'} = [ '=' => undef ] unless $grouping;
		}
#$log->error("DK criteria=" . Data::Dump::dump($criteria));

		@tracks = Slim::Schema->search('Track', $criteria)->all;
#$log->error("DK tracks=" . Data::Dump::dump(@tracks));

	} elsif (defined(my $track_id_list = $request->getParam('track_id'))) {

		# split on commas
		my @track_ids = split(/,/, $track_id_list);

		# keep the order
		my %track_ids_order;
		my $i = 0;
		for my $id (@track_ids) {
			$track_ids_order{$id} = $i++;
		}

		# find the tracks
		my @rawtracks = Slim::Schema->search('Track', { 'id' => { 'in' => \@track_ids } })->all;

		# we might have remote tracks (negative ID) in the list
		foreach ( grep /-\d/, @track_ids ) {
			# We don't have a Slim::Schema::ResultSet::RemoteTrack...
			if ( my $track = Slim::Schema::RemoteTrack->fetchById($_) ) {
				push @rawtracks, $track;
			}
		}

		# sort them back!
		@tracks = sort { $track_ids_order{$a->id()} <=> $track_ids_order{$b->id()} } @rawtracks;

		$artwork = $tracks[0]->album->artwork || 0 if scalar @tracks == 1 && $tracks[0]->album;

	} else {

		# rather than re-invent the wheel, use _playlistXtracksCommand_parseSearchTerms

		my $what = {};

		if (defined(my $genre_id = $request->getParam('genre_id'))) {
			$what->{'genre.id'} = { 'in' => [ split(/,/, $genre_id) ] };
			$info[0] = join(', ', map { $_->name } Slim::Schema->search('Genre', { 'id' => { 'in' => [ split(/,/, $genre_id) ] } })->all);
		}

		if (defined(my $artist_id = $request->getParam('artist_id'))) {
			$what->{'contributor.id'} = $artist_id;
			$info[0] = Slim::Schema->find('Contributor', $artist_id)->name;
		}

		if (defined(my $role_id = $request->getParam('role_id'))) {
			$what->{'contributorTracks.role'} = $role_id;
		}

		if (defined(my $album_id = $request->getParam('album_id'))) {
			$what->{'album.id'} = $album_id;
			my $album = Slim::Schema->find('Album', $album_id);
			@info    = ( $album->title, $album->contributors->first->name );
			$artwork = $album->artwork || 0;
		}

		if (defined(my $year = $request->getParam('year'))) {
			$what->{'year.id'} = $year;
			$info[0] = $year;
		}

		if (defined(my $releaseType = $request->getParam('release_type'))) {
			$what->{'album.release_type'} = {
				in => [ map { uc } split(/, ?/, $releaseType) ]
			};
		}

		if (defined(my $library_id = $request->getParam('library_id'))) {
			$what->{'libraryTracks.library'} = $library_id;
		}

		# Fred: form year_id DEPRECATED in 7.0
		if (defined(my $year_id = $request->getParam('year_id'))) {

			$what->{'year.id'} = $year_id;
		}

		if (defined(my $sort = $request->getParam('sort'))) {
			$what->{'sort'} = $sort;
		}

		@tracks = _playlistXtracksCommand_parseSearchTerms($client, $what, $cmd);
	}

	# don't call Xtracks if we got no songs
	if (@tracks) {

		if ($load || $add || $insert) {

			$info[0] ||= $tracks[0]->title;
			my $token;
			my $showBriefly = 1;
			if ($add) {
				$token = 'JIVE_POPUP_ADDING';
			} elsif ($insert) {
				$token = 'JIVE_POPUP_TO_PLAY_NEXT';
			} else {
				$token = 'JIVE_POPUP_NOW_PLAYING';
				$showBriefly = undef;
			}
			# not to be shown for now playing, as we're pushing to now playing screen now and no need for showBriefly
			if ($showBriefly) {
				my $string = $client->string($token);
				$client->showBriefly({
					'jive' => {
						'type'    => 'mixed',
						'style'   => 'add',
						'text'    => [ $string, $info[0] ],
						'icon-id' => defined $artwork ? Slim::Web::ImageProxy::proxiedImage($artwork) : '/html/images/cover.png',
					}
				});
			}

		}

		$cmd .= "tracks";

		Slim::Control::Request::executeRequest(
			$client, ['playlist', $cmd, 'listRef', \@tracks, undef, $jumpIndex]
		);
	}

	$request->addResult('count', scalar(@tracks));

	$request->setStatusDone();
}


sub playlistsEditCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlists'], ['edit']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $playlist_id = $request->getParam('playlist_id');
	my $cmd = $request->getParam('cmd');
	my $itemPos = $request->getParam('index');
	my $newPos = $request->getParam('toindex');

	if ($request->paramUndefinedOrNotOneOf($cmd, ['up', 'down', 'delete', 'add', 'move'])) {
		$request->setStatusBadParams();
		return;
	}

	if (!$playlist_id) {
		$request->setStatusBadParams();
		return;
	}

	if (!defined($itemPos) && $cmd ne 'add') {
		$request->setStatusBadParams();
		return;
	}

	if (!defined($newPos) && $cmd eq 'move') {
		$request->setStatusBadParams();
		return;
	}

	# transform the playlist id in a playlist obj
	my $playlist = Slim::Schema->find('Playlist', $playlist_id);

	if (!blessed($playlist)) {
		$request->setStatusBadParams();
		return;
	}

	# now perform the operation
	my @items   = $playlist->tracks;
	my $changed = 0;

	# Once we move to using DBIx::Class::Ordered, most of this code can go away.
	if ($cmd eq 'delete') {

		splice(@items, $itemPos, 1);

		$changed = 1;

	} elsif ($cmd eq 'up') {

		# Up function - Move entry up in list
		if ($itemPos != 0) {

			my $item = $items[$itemPos];
			$items[$itemPos] = $items[$itemPos - 1];
			$items[$itemPos - 1] = $item;

			$changed = 1;
		}

	} elsif ($cmd eq 'down') {

		# Down function - Move entry down in list
		if ($itemPos != scalar(@items) - 1) {

			my $item = $items[$itemPos];
			$items[$itemPos] = $items[$itemPos + 1];
			$items[$itemPos + 1] = $item;

			$changed = 1;
		}

	} elsif ($cmd eq 'move') {

		if ($itemPos != $newPos && $itemPos < scalar(@items) && $itemPos >= 0
			&& $newPos < scalar(@items)	&& $newPos >= 0) {

			# extract the item to be moved
			my $item = splice @items, $itemPos, 1;
			my @tail = splice @items, ($newPos);
			push @items, $item, @tail;

			$changed = 1;
		}

	} elsif ($cmd eq 'add') {

		# Add function - Add entry it not already in list
		my $found = 0;
		my $title = $request->getParam('title');
		my $url   = $request->getParam('url');

		if ($url) {

			my $playlistTrack = Slim::Schema->updateOrCreate({
				'url'      => $url,
				'readTags' => 1,
				'commit'   => 1,
			});

			for my $item (@items) {

				if ($item->id eq $playlistTrack->id) {

					$found = 1;
					last;
				}
			}

			# XXXX - call ->appendTracks() once this is reworked.
			if ($found == 0) {
				push @items, $playlistTrack;
			}

			if ($title) {
				$playlistTrack->title($title);
				$playlistTrack->titlesort(Slim::Utils::Text::ignoreCaseArticles($title));
				$playlistTrack->titlesearch(Slim::Utils::Text::ignoreCase($title, 1));
			}

			$playlistTrack->update;

			$changed = 1;
		}
	}

	if ($changed) {

		my $log = logger('player.playlist');

		main::INFOLOG && $log->info("Playlist has changed via editing - saving new list of tracks.");

		$playlist->setTracks(\@items);
		$playlist->update;

		if ($playlist->content_type eq 'ssp') {

			main::INFOLOG && $log->info("Writing out playlist to disk..");

			Slim::Formats::Playlists->writeList(\@items, undef, $playlist->url);
		}

		$playlist = undef;

		Slim::Schema->forceCommit;
		Slim::Schema->wipeCaches;
	}

	$request->setStatusDone();
}


sub playlistsDeleteCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlists'], ['delete']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $playlist_id = $request->getParam('playlist_id');

	if (!$playlist_id) {
		$request->setStatusBadParams();
		return;
	}

	# transform the playlist id in a playlist obj
	my $playlistObj = Slim::Schema->find('Playlist', $playlist_id);

	if (!blessed($playlistObj) || !$playlistObj->isPlaylist()) {
		$request->setStatusBadParams();
		return;
	}

	# show feedback if this action came from jive cometd session
	if ($request->source && $request->source =~ /\/slim\/request/) {
		$request->client->showBriefly({
			'jive' => {
				'text'    => [
					$request->string('JIVE_DELETE_PLAYLIST', $playlistObj->name)
				],
			},
		});
	}

	foreach my $client ( Slim::Player::Client::clients() ) {
		if ($client->currentPlaylist && $client->currentPlaylist->id == $playlistObj->id) {
			# must send defined, but falsy value
			$client->currentPlaylist(0);
			$client->currentPlaylistUpdateTime(Time::HiRes::time());
		}
	}

	_wipePlaylist($playlistObj);

	$request->setStatusDone();
}


sub _wipePlaylist {
	my $playlistObj = shift;

	if ( ! ( blessed($playlistObj) && $playlistObj->isPlaylist() ) ) {
		Slim::Utils::Log::logBacktrace('PlaylistObj not right for this sub: ' . $playlistObj);
		return 0;
	}

	Slim::Player::Playlist::removePlaylistFromDisk($playlistObj);

	# Do a fast delete, and then commit it.
	$playlistObj->setTracks([]);
	$playlistObj->delete;

	$playlistObj = undef;

	Slim::Schema->forceCommit;

}


sub playlistsNewCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlists'], ['new']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# can't do much without playlistdir!
	if (!Slim::Utils::Misc::getPlaylistDir()) {
		$request->setStatusBadConfig();
		return;
	}

	# get the parameters
	my $title  = $request->getParam('name');
	$title = Slim::Utils::Misc::cleanupFilename($title);

	my $titlesort = Slim::Utils::Text::ignoreCaseArticles($title);

	# create the playlist URL
	my $newUrl   = Slim::Utils::Misc::fileURLFromPath(
		catfile(Slim::Utils::Misc::getPlaylistDir(), Slim::Utils::Unicode::encode_locale($title) . '.m3u')
	);

	my $existingPlaylist = Slim::Schema->objectForUrl({
		'url' => $newUrl,
		'playlist' => 1,
	});

	if (blessed($existingPlaylist)) {

		# the name already exists!
		$request->addResult("overwritten_playlist_id", $existingPlaylist->id());
	}
	else {

		my $playlistObj = Slim::Schema->updateOrCreate({

			'url' => $newUrl,
			'playlist' => 1,

			'attributes' => {
				'TITLE' => $title,
				'CT'    => 'ssp',
			},
		});

		$playlistObj->set_column('titlesort', $titlesort);
		$playlistObj->update;

		Slim::Schema->forceCommit;

		Slim::Player::Playlist::scheduleWriteOfPlaylist(undef, $playlistObj);

		$request->addResult('playlist_id', $playlistObj->id);
	}

	$request->setStatusDone();
}


sub playlistsRenameCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['playlists'], ['rename']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $playlist_id = $request->getParam('playlist_id');
	my $newName = $request->getParam('newname');
	my $dry_run = $request->getParam('dry_run');

	if (!$playlist_id || !$newName) {
		$request->setStatusBadParams();
		return;
	}

	# transform the playlist id in a playlist obj
	my $playlistObj = Slim::Schema->find('Playlist', $playlist_id);

	if (!blessed($playlistObj)) {
		$request->setStatusBadParams();
		return;
	}

	$newName = Slim::Utils::Misc::cleanupFilename($newName);

	# now perform the operation

	my $newUrl   = Slim::Utils::Misc::fileURLFromPath(
		catfile(Slim::Utils::Misc::getPlaylistDir(), Slim::Utils::Unicode::encode_locale($newName) . '.m3u')
	);

	my $existingPlaylist = Slim::Schema->objectForUrl({
		'url' => $newUrl,
		'playlist' => 1,
	});

	if (blessed($existingPlaylist)) {

		$request->addResult("overwritten_playlist_id", $existingPlaylist->id());
	}

	if (!$dry_run) {

		if (blessed($existingPlaylist) && $existingPlaylist->id ne $playlistObj->id) {

			Slim::Control::Request::executeRequest(undef, ['playlists', 'delete', 'playlist_id:' . $existingPlaylist->id]);

			$existingPlaylist = undef;
		}

		my $index = Slim::Formats::Playlists::M3U->readCurTrackForM3U( $playlistObj->path );

		Slim::Player::Playlist::removePlaylistFromDisk($playlistObj);

		$playlistObj->set_column('url', $newUrl);
		$playlistObj->set_column('urlmd5', md5_hex($newUrl));
		$playlistObj->set_column('title', $newName);
		$playlistObj->set_column('titlesort', Slim::Utils::Text::ignoreCaseArticles($newName));
		$playlistObj->set_column('titlesearch', Slim::Utils::Text::ignoreCase($newName, 1));
		$playlistObj->set_column('updated_time', time());
		$playlistObj->update;

		# tell clients to pick up the new name
		foreach my $client ( Slim::Player::Client::clients() ) {
			if ($client->currentPlaylist && $client->currentPlaylist->id == $playlistObj->id) {
				$client->currentPlaylist($playlistObj);
				$client->currentPlaylistUpdateTime(Time::HiRes::time());
			}
		}

		# check whether we're saving the current player's track queue as a playlist
		my $client = $request->client;
		if ($client && !$client->currentPlaylist) {
			my $playlistTrackIds = join(':', map { $_->id } $playlistObj->tracks);
			my $playerTrackIds = join(':', map { $_->id} @{$client->playlist});

			if ($playlistTrackIds eq $playerTrackIds) {
				$client->currentPlaylist($playlistObj);
				$client->currentPlaylistUpdateTime(Time::HiRes::time());
				$client->currentPlaylistModified(0);
			}
		}

		if (!defined Slim::Formats::Playlists::M3U->write(
			[ $playlistObj->tracks ],
			undef,
			$playlistObj->path,
			1,
			$index,
		)) {
			$request->addResult('writeError', 1);
		}

		# plugin hook
		if ( Slim::Utils::Scanner::API->can('getHandlers') ) {
			my $pluginHandlers = Slim::Utils::Scanner::API->getHandlers();
			if ( my $handler = $pluginHandlers->{onNewPlaylistHandler} ) {
				$handler->( { id => $playlistObj->id, obj => $playlistObj, url => $playlistObj->url } );
			}
		}
	}

	$request->setStatusDone();
}


sub powerCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['power']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $newpower = $request->getParam('_newvalue');
	my $noplay   = $request->getParam('_noplay');
	my $sequenceNumber = $request->getParam('seq_no');
	if (defined $sequenceNumber) {
		$client->sequenceNumber($sequenceNumber)
	}

	# handle toggle
	if (!defined $newpower) {
		$newpower = $client->power() ? 0 : 1;
	}

	if ($newpower == $client->power()) {return;}

	# handle sync'd players
	if ($client->isSynced()) {

		my @buddies = $client->syncedWith();

		for my $eachclient (@buddies) {
			$eachclient->power($newpower, 1) if $prefs->client($eachclient)->get('syncPower');

			# send an update for Jive player power menu
			Slim::Control::Jive::playerPower($eachclient);

		}
	}

	$client->power($newpower, $noplay);

	# Powering off cancels sleep...
	if ($newpower eq "0") {
		Slim::Utils::Timers::killTimers($client, \&_sleepStartFade);
		Slim::Utils::Timers::killTimers($client, \&_sleepPowerOff);
		$client->sleepTime(0);
		$client->currentSleepTime(0);
	}

	# send an update for Jive player power menu
	Slim::Control::Jive::playerPower($client);

	$request->setStatusDone();
}


sub prefCommand {
	my $request = shift;

	if ($request->isNotCommand([['pref']]) && $request->isNotCommand([['playerpref']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client;

	if ($request->isCommand([['playerpref']])) {

		$client = $request->client();

		unless ($client) {
			$request->setStatusBadDispatch();
			return;
		}
	}

	# get our parameters
	my $prefName = $request->getParam('_prefname');
	my $newValue = $request->getParam('value') || $request->getParam('_newvalue');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*?):(.+)$/) {
		$namespace = $1;
		$prefName = $2;
	}

	if ($newValue =~ /^value:/) {
		$newValue =~ s/^value://;
	}

	if (!defined $prefName || !defined $newValue || !defined $namespace) {
		$request->setStatusBadParams();
		return;
	}

	if ($client) {
		preferences($namespace)->client($client)->set($prefName, $newValue);
	}
	else {
		preferences($namespace)->set($prefName, $newValue);
	}

	$request->setStatusDone();
}

sub rescanCommand {
	my $request = shift;

	if ($request->isNotCommand([['rescan']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $originalMode;
	my $mode = $originalMode = $request->getParam('_mode') || 'full';
	my $singledir = $request->getParam('_singledir');

	if ($singledir) {
		$singledir = Slim::Utils::Misc::pathFromFileURL($singledir);

		# don't run scan if newly added entry is disabled for all media types
		if ( grep { /\Q$singledir\E/ } @{ Slim::Utils::Misc::getInactiveAudioDirs() }) {
			main::INFOLOG && $log->info("Ignore scan request for folder, it's disabled for all media types: $singledir");
			$request->setStatusDone();
			return;
		}
	}

	# if scan is running or we're told to queue up requests, return quickly
	# FIXME - this seems to sometimes lead to infinite loops! (see eg. Synology change)
	if ( Slim::Music::Import->stillScanning() || Slim::Music::Import->doQueueScanTasks() || Slim::Music::Import->hasScanTask() ) {
		Slim::Music::Import->queueScanTask($request);

		# trigger the scan queue if we're not scanning yet
		Slim::Music::Import->nextScanTask() unless Slim::Music::Import->stillScanning() || Slim::Music::Import->doQueueScanTasks();

		$request->setStatusDone();
		return;
	}

	# Bug 17358, if any plugin importers are enabled such as iTunes/MusicIP, run an old-style external rescan
	# XXX Rewrite iTunes and MusicIP to support async rescan
	my $importers = Slim::Music::Import->importers();
	while ( my ($class, $config) = each %{$importers} ) {
		if ( $class =~ /(?:Plugin|Slim::Music::VirtualLibraries)/ && $config->{use} ) {
			$mode = 'external';
			last;
		}
	}

	if ( $mode eq 'external' ) {
		# The old way of rescanning using scanner.pl
		my %args = ();

		if ($originalMode =~ /playlists|onlinelibrary/) {
			$args{$originalMode} = 1;
		}
		else {
			$args{rescan} = 1;
		}

		$args{singledir} = $singledir if $singledir;

		Slim::Music::Import->launchScan(\%args);
	}
	else {
		# In-process scan

		my @dirs = @{ Slim::Utils::Misc::getMediaDirs() };
		# if we're scanning already, don't do it twice
		if (scalar @dirs) {

			if ( Slim::Utils::OSDetect::getOS->canAutoRescan && $prefs->get('autorescan') ) {
				require Slim::Utils::AutoRescan;
				Slim::Utils::AutoRescan->shutdown;
			}

			Slim::Utils::Progress->clear();

			if ($mode eq 'playlists') {
				my $playlistdir = Slim::Utils::Misc::getPlaylistDir();

				# XXX until libmediascan supports audio, run the audio scanner now
				Slim::Utils::Scanner::Local->rescan( $playlistdir, {
					types    => 'list',
					scanName => 'playlist',
					progress => 1,
				} );
			}
			else {
				my $audiodirs = Slim::Utils::Misc::getAudioDirs($singledir);

				if (my $playlistdir = Slim::Utils::Misc::getPlaylistDir()) {
					# scan playlist folder too
					push @$audiodirs, $playlistdir;
				}

				# XXX until libmediascan supports audio, run the audio scanner now
				Slim::Utils::Scanner::Local->rescan( $audiodirs, {
					types    => 'list|audio',
					scanName => 'directory',
					progress => 1,
				} ) if scalar @$audiodirs;
			}
		}
	}

	$request->setStatusDone();
}

sub showCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['show']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client     = $request->client();
	my $line1      = $request->getParam('line1');
	my $line2      = $request->getParam('line2');
	my $duration   = $request->getParam('duration');
	my $brightness = $request->getParam('brightness');
	my $font       = $request->getParam('font');
	my $centered   = $request->getParam('centered');
	my $screen     = $request->getParam('screen');

	if (!defined $line1 && !defined $line2) {
		$request->setStatusBadParams();
		return;
	}

	$brightness = $client->maxBrightness() unless defined($brightness);
	$duration = 3 unless defined($duration);

	my $hash = {};

	if ($centered) {
		$hash->{'center'} = [$line1, $line2];
	}
	else {
		$hash->{'line'} = [$line1, $line2];
	}

	if ($font eq 'huge') {
		$hash->{'fonts'} = {
			'graphic-320x32' => 'full',
			'graphic-160x32' => 'full_n',
			'graphic-280x16' => 'huge',
			'text'           => 1,
		};
	}
	else {
		$hash->{'fonts'} = {
			'graphic-320x32' => 'standard',
			'graphic-160x32' => 'standard_n',
			'graphic-280x16' => 'medium',
			'text'           => 2,
		};
	}

	if (defined $screen && $screen == 2) {
		$hash = { 'screen2' => $hash };
	}

	# get out of the screensaver if one is active
	# we'll get back to it as soon as done (automatically)
	if (Slim::Buttons::Common::mode($client) =~ /screensaver/i) {
		Slim::Buttons::Common::popMode($client);
	}

	# call showBriefly for the magic!
	$client->showBriefly($hash,
		$duration,
		0,  # line2 is single line
		1,  # block updates
		1,  # scroll to end
		$brightness,
		\&Slim::Control::Commands::_showCommand_done,
		{ 'request' => $request }
	);

	# we're not done yet
	$request->setStatusProcessing();
}

sub sleepCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['sleep']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client        = $request->client();
	my $will_sleep_in = $request->getParam('_newvalue');

	if (!defined $will_sleep_in) {
		$request->setStatusBadParams();
		return;
	}


	# Cancel the timers, we'll set them back if needed
	Slim::Utils::Timers::killTimers($client, \&_sleepStartFade);
	Slim::Utils::Timers::killTimers($client, \&_sleepPowerOff);

	# if we have a sleep duration
	if ($will_sleep_in > 0) {

		my $now = Time::HiRes::time();

		# this is when we want to power off
		my $offTime = $now + $will_sleep_in;

		# this is the time we have to fade
		my $fadeDuration = $offTime - $now - 1;
		# fade for the last 60 seconds max
		$fadeDuration = 60 if ($fadeDuration > 60);

		# time at which we start fading
		my $fadeTime = $offTime - $fadeDuration;

		# set our timers
		Slim::Utils::Timers::setTimer($client, $offTime, \&_sleepPowerOff);
		Slim::Utils::Timers::setTimer($client, $fadeTime,
			\&_sleepStartFade, $fadeDuration);

		$client->sleepTime($offTime);
		# for some reason this is minutes...
		$client->currentSleepTime($will_sleep_in / 60);

		my $will_sleep_in_minutes = int( $will_sleep_in / 60 );
		# only show a showBriefly if $will_sleep_in_minutes has a style on SP side
		my $validSleepStyles = {
			'15' => 1,
			'30' => 1,
			'45' => 1,
			'60' => 1,
			'90' => 1,
		};
		if ($validSleepStyles->{$will_sleep_in_minutes}) {
			$client->showBriefly({
				'jive' => {
					'type'    => 'icon',
					'style'   => 'sleep_' . $will_sleep_in_minutes,
					'text'    => [ $will_sleep_in_minutes ],
				}
			});
		} else {
			my $sleepTime = $client->prettySleepTime;
                	$client->showBriefly( {
				'jive' =>
					{
						'type'    => 'popupplay',
						'text'    => [ $sleepTime ],
					},
			});
		}

	} else {

		# finish canceling any sleep in progress
		$client->sleepTime(0);
		$client->currentSleepTime(0);

		$client->showBriefly({
			'jive' => {
				'type'    => 'icon',
				'style'	  => 'sleep_cancel',
				'text'    => [ '' ],
			}
		});

	}


	$request->setStatusDone();
}


sub stopServer {
	my $request = shift;

	if ($request->isNotCommand([['stopserver']]) && $request->isNotCommand([['restartserver']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# pass true value if we want to restart the server
	if ($request->isCommand([['restartserver']])) {
		main::restartServer();
	}
	else {
		main::stopServer();
	}

	$request->setStatusDone();
}


sub syncCommand {
	my $request = shift;

	# check this is the correct command.
	if ($request->isNotCommand([['sync']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $newbuddy = $request->getParam('_indexid-');
	my $noRestart= $request->getParam('noRestart');

	if (!defined $newbuddy) {
		$request->setStatusBadParams();
		return;
	}

	if ($newbuddy eq '-') {

		$client->controller()->unsync($client);

	} else {

		# try an ID
		my $buddy = Slim::Player::Client::getClient($newbuddy);

		# try a player index
		if (looks_like_number($newbuddy) && !defined $buddy) {
			my @clients = Slim::Player::Client::clients();
			if (defined $clients[$newbuddy]) {
				$buddy = $clients[$newbuddy];
			}
		}

		$client->controller()->sync($buddy, $noRestart) if defined $buddy;
	}

	$request->setStatusDone();
}


sub timeCommand {
	my $request = shift;

	# check this is the correct command.
	# "gototime" is deprecated
	if ($request->isNotCommand([['time', 'gototime']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client  = $request->client();
	my $newtime = $request->getParam('_newvalue');

	if (!defined $newtime) {
		$request->setStatusBadParams();
		return;
	}

	Slim::Player::Source::gototime($client, $newtime);

	$request->setStatusDone();
}


sub wipecacheCommand {
	my $request = shift;

	if ($request->isNotCommand([['wipecache']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# if we're scanning already, don't do it twice
	if ( Slim::Music::Import->stillScanning() || Slim::Music::Import->doQueueScanTasks || $request->getParam('_queue') ) {
		Slim::Music::Import->queueScanTask($request);
	}

	else {

		# replace local tracks with volatile versions - we're gong to wipe the database
		for my $client (Slim::Player::Client::clients()) {

			Slim::Player::Playlist::makeVolatile($client);
		}

		if ( Slim::Utils::OSDetect::getOS->canAutoRescan && $prefs->get('autorescan') ) {
			require Slim::Utils::AutoRescan;
			Slim::Utils::AutoRescan->shutdown;
		}

		Slim::Utils::Progress->clear();

		# Launch external scanner on normal systems
		Slim::Music::Import->launchScan( {
			wipe => 1,
		} );
	}

	$request->setStatusDone();
}

sub ratingCommand {
	my $request = shift;

	# check this is the correct command.
	if ( $request->isNotCommand( [['rating']] ) ) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $item   = $request->getParam('_item');      #p1
	my $rating = $request->getParam('_rating');    #p2, optional

	if ( !defined $item ) {
		$request->setStatusBadParams();
		return;
	}

	if ( defined $rating ) {
		main::INFOLOG && $log->info("Setting rating for $item to $rating");
	}

	my $track = blessed($item);

	if ( !$track ) {
		# Look for track based on ID or URL
		if ( $item =~ /^\d+$/ ) {
			$track = Slim::Schema->rs('Track')->find($item);
		}
		else {
			my $url = Slim::Utils::Misc::fileURLFromPath($item);
			if ( $url ) {
				$track = Slim::Schema->objectForUrl( { url => $url } );
			}
		}
	}

	if ( !blessed($track) || $track->audio != 1 || track->remote ) {
		$log->warn("Can't find local track: $item");
		$request->setStatusBadParams();
		return;
	}

	if ( defined $rating ) {
		if ( $rating < 0 || $rating > 100 ) {
			$request->setStatusBadParams();
			return;
		}

		Slim::Schema->rating( $track, $rating );
	}
	else {
		$rating = Slim::Schema->rating($track);

		$request->addResult( '_rating', defined $rating ? $rating : 0 );
	}

	$request->setStatusDone();
}

sub pragmaCommand {
	my $request = shift;

	my $pragma = join( ' ', grep { $_ ne 'pragma' } $request->renderAsArray );

	# XXX need to pass pragma to artwork cache even if using MySQL
	Slim::Utils::OSDetect->getOS()->sqlHelperClass()->pragma($pragma);

	$request->setStatusDone();
}

################################################################################
# Helper functions
################################################################################

sub _sleepStartFade {
	my $client = shift;
	my $fadeDuration = shift;

	if ($client->isPlayer()) {
		$client->fade_volume(-$fadeDuration);
	}
}

sub _sleepPowerOff {
	my $client = shift;

	$client->sleepTime(0);
	$client->currentSleepTime(0);

	Slim::Control::Request::executeRequest($client, ['stop']);
	Slim::Control::Request::executeRequest($client, ['power', 0]);
}


sub _mixer_mute {
	my $client = shift;

	$client->mute();
}

sub _playlistXitem_load_done {
	my ($client, $index, $request, $count, $url, $error, $noShuffle, $fadeIn, $noplay, $wipePlaylist) = @_;

	# dont' keep current song on loading a playlist
	if ( !$noShuffle ) {
		Slim::Player::Playlist::reshuffle($client,
			(Slim::Player::Source::playmode($client) eq "play" || ($client->power && Slim::Player::Source::playmode($client) eq "pause")) ? 0 : 1
		);
	}

	if (defined($index)) {
		$client->execute(['playlist', 'jump', $index, $fadeIn, $noplay ]);
	}

	# XXX: this should not be calling a request callback directly!
	# It should be handled by $request->setStatusDone
	if ( my $callbackf = $request->callbackFunction ) {
		if ( my $callbackargs = $request->callbackArguments ) {
			$callbackf->( @{$callbackargs} );
		}
		else {
			$callbackf->( $request );
		}
	}

	if ($wipePlaylist) {
		my $playlistObj = Slim::Schema->objectForUrl($url);

		if ($playlistObj && blessed($playlistObj) && $playlistObj->isPlaylist()) {
			_wipePlaylist($playlistObj);
		}
	}

	Slim::Control::Request::notifyFromArray($client, ['playlist', 'load_done']);
}


sub _insert_done {
	my ($client, $size, $callbackf, $callbackargs) = @_;

	$callbackf && (&$callbackf(@$callbackargs));

	Slim::Control::Request::notifyFromArray($client, ['playlist', 'load_done']);
}


sub _playlistXalbum_singletonRef {
	my $arg = shift;

	if (!defined($arg)) {
		return [];
	} elsif ($arg eq '*') {
		return [];
	} elsif ($arg) {
		# force stringification of a possible object.
		return ["" . $arg];
	} else {
		return [];
	}
}


sub _playlistXtracksCommand_parseSearchTerms {
	my $client = shift;
	my $what   = shift;
	my $cmd    = shift;

	# if there isn't an = sign, then change the first : to a =
	if ($what !~ /=/) {
		$what =~ s/(.*)?:(.*)/$1=$2/;
	}

	my %find   = ();
	my $terms  = {};
	my %attrs  = ();
	my @fields = map { lc($_) } Slim::Schema->sources;
	my ($sort, $limit, $offset);

	# Bug: 3629 - sort by album, then disc, tracknum, titlesort
	my $sqlHelperClass = Slim::Utils::OSDetect->getOS()->sqlHelperClass();

	my $collate = $sqlHelperClass->collate();

	my $albumSort = $sqlHelperClass->append0("album.titlesort") . " $collate"
		. ', me.disc, me.tracknum, ' . $sqlHelperClass->append0("me.titlesort") . " $collate";
	my $albumYearSort = $sqlHelperClass->append0("album.year") . ", " . $albumSort;
	my $trackSort = "me.disc, me.tracknum, " . $sqlHelperClass->append0("me.titlesort") . " $collate";

	if ( !Slim::Schema::hasLibrary()) {
		return ();
	}

	# Setup joins as needed - we want to end up with Tracks in the end.
	my %joinMap = ();

	# Accept both the old key=value "termlist", and internal use by passing a hash ref.
	if (ref($what) eq 'HASH') {

		$terms = $what;

	} else {

		for my $term (split '&', $what) {

			# If $terms has a leading &, split will generate an initial empty string
			next if !$term;

			if ($term =~ /^(.*)=(.*)$/ && grep { $1 =~ /$_\.?/ } @fields) {

				my $key   = URI::Escape::uri_unescape($1);
				my $value = URI::Escape::uri_unescape($2);

				$terms->{$key} = $value;

			}
			elsif ($term =~ /^(library_id)=(.*)/) {
				$terms->{'librarytracks.library'} = URI::Escape::uri_unescape($2);
			}
		}
	}

	my $library_id;
	while (my ($key, $value) = each %{$terms}) {

		# ignore anti-CSRF token
		if ($key eq 'pageAntiCSRFToken') {
			next;
		}

		# Bug: 4063 - don't enforce contributor.role when coming from
		# the web UI's search.
		elsif ($key eq 'contributor.role') {
			next;
		}

		elsif ($key eq 'contributorTracks.role') {
			my @roles = split(/,\s*/, $value);
			push @roles, 'ARTIST' if $value =~ /^(?:ALBUMARTIST|5)$/ && !$prefs->get('useUnifiedArtistsList');
			$find{$key} = [ { 'in' => [ map { Slim::Schema::Contributor->typeToRole($_) || $_ } @roles ] } ];
			$joinMap{'contributorTracks'} = { 'contributorTracks' => 'track' };
			next;
		}

		elsif (lc($key) eq 'librarytracks.library') {
			$library_id = $value;
			next;
		}

		# Bug: 3582 - reconstitute from 0 for album.compilation.
		elsif ($key eq 'album.compilation' && $value == 0) {

			$find{$key} = [ { 'is' => undef }, { '=' => 0 } ];
		}

		elsif ($key eq 'album.release_type') {
			$find{$key} = [ {'=' => uc($value) } ];
			$joinMap{'contributorTracks'} = { }
		}

		# Do some mapping from the player browse mode. This is
		# already done in the web ui.
		elsif ($key =~ /^(playlist|age|album|contributor|genre|year)$/) {
			$key = "$1.id";
		}

		# New Music browsing is working on the
		# tracks.timestamp column, but shows years.
		# Use the album-id in the track instead of joining with the album table.
		if ($key eq 'album.id' || $key eq 'age.id') {
			$key = 'track.album';
		}

		# Setup the join mapping
		if ($key =~ /^genre\./) {

			$sort = $albumSort;
			$joinMap{'genre'} = { 'genreTracks' => 'genre' };

		} elsif ($key =~ /^album\./) {

			$sort = $albumSort;
			$joinMap{'album'} = 'album';

		} elsif ($key =~ /^year\./) {

			$sort = $albumSort;
			$joinMap{'year'} = 'year';

		} elsif ($key =~ /^work\./) {

			$sort = $albumSort;
			$joinMap{'work'} = 'work';

		} elsif ($key =~ /^contributor\./) {

			$sort = $albumSort;
			$joinMap{'contributor'} = { 'contributorTracks' => 'contributor' };
		}

		# Turn 'track.*' into 'me.*'
		if ($key =~ /^(playlist)?track(\.?.*)$/) {
			$key = "me$2";
		}

		# Meta tags that are passed.
		if ($key =~ /^(?:limit|offset)$/) {

			$attrs{$key} = $value;

		} elsif ($key ne 'sort') { # 'sort' handled afterwards...

			if ($key =~ /\.(?:name|title)search$/) {

				# BUG 4536: if existing value is a hash, don't create another one
				if (ref $value eq 'HASH') {
					$find{$key} = $value;
				} else {
					$find{$key} = { 'like' => Slim::Utils::Text::searchStringSplit($value) };
				}

			} elsif ( $key eq 'me.grouping' ) {
#$log->error("DK value=$value");

				$find{$key} = $value || undef;

			} else {

				$find{$key} = Slim::Utils::Text::ignoreCase($value, 1);
			}
		}
	}

	# Check for 'sort' after iterating other keys, so that it takes precedence...
	if (defined($terms->{'sort'})) {
		my $value = $terms->{'sort'};

		if ($value eq 'artflow' || $value eq 'yearartistalbum' || $value eq 'yearalbum') {
			# If its an album sort where year takes precedence, then sort by year first
			if ($sort eq $albumSort) {
				$sort = $albumYearSort;
			}
		} elsif ($value eq 'album') {
			$sort = $albumSort;
		} elsif ($value !~ /^(artistalbum|albumtrack|new|random)$/) {
			# Only use sort value if it is **not** an album sort.
			$sort = $value;
		}
	}

	if ($find{'playlist.id'} && !$find{'me.id'}) {

		# Treat playlists specially - they are containers.
		my $playlist = Slim::Schema->find('Playlist', $find{'playlist.id'});

		if (blessed($playlist) && $playlist->can('tracks')) {

			$client->currentPlaylist($playlist) if $cmd && $cmd =~ /^(?:play|load)/;

			return $playlist->tracks($library_id);
		}

		return ();

	} else {

		# on search, only grab audio items.
		$find{'me.audio'} = 1;

		my $vaObjId = Slim::Schema->variousArtistsObject->id;

		if ($find{'contributor.id'} && $find{'contributor.id'} == $vaObjId) {

			$find{'album.compilation'} = 1;
			$joinMap{'albums'} = 'album';
		}

		# Bug 2271 - allow VA albums.
		if (defined $find{'album.compilation'} && $find{'album.compilation'} == 1) {

			delete $find{'contributor.id'};
		}

		if ($find{'me.album'} && $find{'contributor.id'} &&
			$find{'contributor.id'} == $vaObjId) {

			delete $find{'contributor.id'};
		}

		if ($find{'playlist.id'}) {

			delete $find{'playlist.id'};
		}

		# If we have an album and a year - remove the year, since
		# there is no explict relationship between Track and Year.
		if ($find{'me.album'} && $find{'year.id'}) {

			delete $find{'year.id'};
			delete $joinMap{'year'};

		} elsif ($find{'year.id'}) {

			$find{'album.year'} = delete $find{'year.id'};
			delete $joinMap{'year'};
		}

		if ($sort && ($sort eq $albumSort || $sort eq $albumYearSort)) {
			if ($find{'me.album'}) {
				# Don't need album-sort if we have a specific album-id
				$sort = undef;
			} else {
				# Bug: 3629 - if we're sorting by album - be sure to include it in the join table.
				$joinMap{'album'} = 'album';
			}
		}

		if ( $library_id ||= Slim::Music::VirtualLibraries->getLibraryIdForClient($client) ) {
			if ( Slim::Music::VirtualLibraries->getRealId($library_id) ) {
				$joinMap{'libraryTracks'} = 'libraryTracks';
				$find{'libraryTracks.library'} = $library_id;
			}
		}

		# limit & offset may have been populated above.
		$attrs{'order_by'} = $sort || $trackSort;
		$attrs{'join'}     = [ map { $_ } values %joinMap ];

		return Slim::Schema->rs('Track')->search(\%find, \%attrs)->distinct->all;
	}
}

sub _playlistXtracksCommand_constructTrackList {
	my $client  = shift;
	my $term    = shift;
	my $list    = shift;

	my @list = split (/,/, $list);
	my @tracks = ();
	for my $url ( @list ) {
		my $track = Slim::Schema->objectForUrl($url);
		push @tracks, $track if blessed($track) && $track->id;
	}

	return @tracks;

}

sub _playlistXtracksCommand_parseListRef {
	my $client  = shift;
	my $term    = shift;
	my $listRef = shift;

	if ($term =~ /listref=(\w+)&?/i) {
		$listRef = $client->modeParam($1);
	}

	if (defined $listRef && ref $listRef eq "ARRAY") {

		return @$listRef;
	}

	return ();
}

sub _playlistXtracksCommand_parseSearchRef {
	my $client    = shift;
	my $term      = shift;
	my $searchRef = shift;

	if ($term =~ /searchRef=(\w+)&?/i) {
		$searchRef = $client->modeParam($1);
	}

	my $cond = $searchRef->{'cond'} || {};
	my $attr = $searchRef->{'attr'} || {};

	# XXX - For some reason, the join key isn't passed along with the ref.
	# Perl bug because 'join' is a keyword?
	if (!$attr->{'join'} && $attr->{'joins'}) {
		$attr->{'join'} = delete $attr->{'joins'};
	}

	return Slim::Schema->rs('Track')->search($cond, $attr)->distinct->all;
}

# Allow any URL to be a favorite - this includes things like iTunes playlists.
sub _playlistXtracksCommand_parseDbItem {
	my $client  = shift;
	my $url     = shift;

	my %classes;
	my $class   = 'Track';

	# Bug: 2569
	# We need to ask for the right type of object.
	#
	# Contributors, Genres & Albums have a url of:
	# db:contributor.namesearch=BEATLES
	#
	# Remote playlists are Track objects, not Playlist objects.
	if ($url =~ /^db:(\w+\.\w+=.+)$/) {

		for my $term ( split '&', $1 ) {

			# If $terms has a leading &, split will generate an initial empty string
			next if !$term;

			if ($term =~ /^(\w+)\.(\w+)=(.*)$/) {

				my $key   = URI::Escape::uri_unescape($2);
				my $value = URI::Escape::uri_unescape($3);

				if (!utf8::is_utf8($value) && !utf8::decode($value)) { $log->warn("The following value is not UTF-8 encoded: $value"); }

				if (utf8::is_utf8($value)) {
					utf8::decode($value);
					utf8::encode($value);
				}

				$class = ucfirst($1);

				if ( $class eq 'LibraryTracks' && $key eq 'library' && $value eq '-1' ) {
					$classes{$class} = -1;
				}
				elsif ( $class eq 'Track' && $key eq 'grouping' ) {
#$log->error("DK value=$value");
					$classes{$class} = $value;
				}
				# album favorites need to be filtered by contributor, too
				elsif ($class eq 'Contributor' && (my $albumObj = $classes{Album})) {
					my $lcClass = lc($class);
					$classes{Album} = Slim::Schema->search('Album', {
						titlesearch => $albumObj->titlesearch,
						"$lcClass.$key" => $value,
					},{
						prefetch => $lcClass
					})->first;
				}
				else {
					$classes{$class} = Slim::Schema->search( $class, { $key => $value } )->first;
				}
			}
		}
	}
	elsif ( Slim::Music::Info::isPlaylist($url) && !Slim::Music::Info::isRemoteURL($url) ) {

		%classes = (
			Playlist => Slim::Schema->rs($class)->objectForUrl( {
				url => $url,
			} )
		);
	}
	else {

		# else we assume it's a track
		%classes = (
			Track => Slim::Schema->rs($class)->objectForUrl( {
				url => $url,
			} )
		);
	}

	# Bug 4790: we get a track object of content type 'dir' if a fileurl for a directory is passed
	# this needs scanning so pass empty list back to playlistXitemCommand in this case
	my $terms = "";
	while ( my ($class, $obj) = each %classes ) {
		if ( blessed($obj) && (
			$class eq 'Album' ||
			$class eq 'Contributor' ||
			$class eq 'Genre' ||
			$class eq 'Year' ||
			$class eq 'Work' ||
			( blessed $obj && $obj->can('content_type') && $obj->content_type ne 'dir')
		) ) {
			$terms .= "&" if ( $terms ne "" );
			$terms .= sprintf( '%s.id=%d', lc($class), $obj->id );
		}
	}

	if ( $classes{LibraryTracks} ) {
		$terms .= "&" if ( $terms ne "" );
		$terms .= sprintf( 'librarytracks.library=%d', $classes{LibraryTracks} );
	}

	if ( defined $classes{Track} ) {
		$terms .= "&" if ( $terms ne "" );
		$terms .= sprintf( 'track.grouping=%s', URI::Escape::uri_escape_utf8($classes{Track}) );
	}

	if ( $terms ne "" ) {
#$log->error("DK terms=$terms");
		return _playlistXtracksCommand_parseSearchTerms($client, $terms);
	}
	else {
		return ();
	}
}

sub _showCommand_done {
	my $args = shift;

	my $request = $args->{'request'};
	my $client = $request->client();

	# now we're done!
	$request->setStatusDone();
}

=head1 SEE ALSO

L<Slim::Control::Request.pm>

=cut

1;

__END__
