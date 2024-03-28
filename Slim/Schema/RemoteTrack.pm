package Slim::Schema::RemoteTrack;

# Logitech Media Server Copyright 2003-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# This is an emulation of the Slim::Schema::Track API for remote tracks

use strict;

use base qw(Slim::Utils::Accessor);

use Scalar::Util qw(blessed);
use Tie::Cache::LRU;

use Slim::Utils::Cache;
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = logger('formats.metadata');
my $prefs = preferences('server');
my $cache;

# Keep a cache of up to x remote tracks at a time - allow more if user claims to have lots of memory.
use constant CACHE_SIZE => 500;
use constant DISK_CACHE_TTL => 60 * 60 * 24 * 30;

use constant INITIAL_BLOCK_ONCE   => 0;
use constant INITIAL_BLOCK_ONSEEK => 1;
use constant INITIAL_BLOCK_ALWAYS => 2;

tie our %Cache, 'Tie::Cache::LRU', CACHE_SIZE;
tie our %idIndex, 'Tie::Cache::LRU', CACHE_SIZE;

my @allAttributes = (qw(
	_url redir
	content_type
	bitrate
	secs

	artistname albumname coverurl type info_link

	title titlesort titlesearch album tracknum
	timestamp added_time updated_time filesize disc audio audio_size audio_offset year
	initial_block_fn
	cover vbr_scale samplerate samplesize channels block_alignment endian
	bpm tagversion drm musicmagic_mixable
	musicbrainz_id lossless lyrics replay_gain replay_peak extid

	urlmd5 virtual

	_comment genre

	dlna_profile
	stash
	error

	work
));

{
	__PACKAGE__->mk_accessor('ro',
		'id',
		'remote',

		# Emulate absent relationships
		qw(
			artist
			albumid
		),
	);

	__PACKAGE__->mk_accessor('rw', @allAttributes);
	__PACKAGE__->mk_accessor('hash', '_processors');
}

sub init {
	$cache = Slim::Utils::Cache->new;

	my $maxPlaylistLengthCB = sub {
		my ($pref, $max) = @_;

		if ($prefs->get('dbhighmem')) {
			$max ||= 2000;
			$max = 2000 if $max < 2000;
		}
		else {
			$max ||= 500;
			$max = 500 if $max > 500;
			$max = 100 if $max < 100;
		}

		my $cacheObj = tied %Cache;
		if ($cacheObj->max_size != $max) {
			$cacheObj->max_size($max);
		}
	};

	$maxPlaylistLengthCB->(undef, $prefs->get('maxPlaylistLength'));

	$prefs->setChange($maxPlaylistLengthCB, 'maxPlaylistLength');
}

# Emulate absent methods - hopefully these can be retired at some time
sub artists {return ();}
sub artistid {}
sub genres {return ();}
sub genrename {}
sub genreid {}
sub coverArtExists {0}

sub isRemoteURL {shift->remote();}

sub path {
	my $url = shift->_url();

	if ( $url =~ s/^tmp/file/ ) {
		return Slim::Utils::Misc::pathFromFileURL($url);
	}

	return $url;
}

sub comment {
	my ($self, $new) = @_;

	if (defined $new) {
		$self->_comment(_mergeComments($new));
	}

	# if the comment is a list, merge those lines
	if (ref $self->_comment && ref $self->_comment eq 'ARRAY') {
		$self->_comment(_mergeComments($self->_comment));
	}

	return $self->_comment;
}

sub processors {
	my ($self, $type, $initial_block_type, $init) = @_;

	return $self->_processors unless $type;

	if (defined $initial_block_type || defined $init) {
		$self->_processors($type, {
					initial_block_type => $initial_block_type,
					init => $init,
				} );
	}

	return $self->_processors($type);
}

sub _mergeComments {
	my $new = shift;

	if (ref $new && ref $new eq 'ARRAY') {
		my $comment;

		foreach my $c (@$new) {
			# join multiple comments into a single multi-line comment
			# consistent with Slim::Schema::Track::comment
			$comment .= "\n" if $comment;
			$comment .= $c;
		}

		$new = $comment if $comment;
	}

	return $new;
}

sub contributorsOfType {}

sub update {}
sub delete {}

sub DESTROY {
	my $self = shift;

	unlink $self->initial_block_fn if $self->initial_block_fn;

	$self->SUPER::DESTROY();
}

*retrievePersistent = \&Slim::Schema::Track::retrievePersistent;
*playcount = \&Slim::Schema::Track::playcount;
*rating = \&Slim::Schema::Track::rating;
*lastplayed = \&Slim::Schema::Track::lastplayed;

sub displayAsHTML {
	my ($self, $form, $descend, $sort) = @_;

	my $format = Slim::Music::Info::standardTitleFormat();

	$form->{'plugin_meta'}->{'title'} ||= $self->name;

	# Go directly to infoFormat, as standardTitle is more client oriented.
	$form->{'text'}     = Slim::Music::TitleFormatter::infoFormat($self, $format, 'TITLE', $form->{'plugin_meta'});
	$form->{'item'}     = $self->id;
	$form->{'itemobj'}  = $self;
	$form->{'coverid'}  = $self->coverid;

	# Only include Artist & Album if the user doesn't have them defined in a custom title format.
	if ( $format !~ /ARTIST/ && $form->{'plugin_meta'} && $form->{'plugin_meta'}->{'artist'} ) {
		$form->{'includeArtist'} = 1;
	}

	if ( $format !~ /ALBUM/ && $form->{'plugin_meta'} && $form->{'plugin_meta'}->{'album'} ) {
		$form->{'includeAlbum'}  = 1;
	}

	$form->{'noArtist'} = Slim::Utils::Strings::string('NO_ARTIST');
	$form->{'noAlbum'}  = Slim::Utils::Strings::string('NO_ALBUM');
}

sub name {
	return shift->title;
}

sub namesort {
	return shift->titlesort;
}

sub contributorRoles {
	my $self = shift;

	return Slim::Schema::Contributor->contributorRoles;
}

sub artistName {
	return shift->artistname(@_);
}

sub coverArt {
	my $self    = shift;
	my $list    = shift || 0;

	my ($body, $contentType, $mtime, $path);

#	my $cover = $self->cover;
#
#	return undef if defined $cover && !$cover;

	# Remote files may have embedded cover art
	my $image = $cache->get( 'cover_' . $self->_url );

	return undef if !$image;

	$body        = $image->{image};
	$contentType = $image->{type};
	$mtime       = time();

	if ( !$list && wantarray ) {
		return ( $body, $contentType, time() );
	} else {
		return $body;
	}
}

# Although the URL is the primary key into the cache,
# we allow it to be updated
sub url {
	my ($self, $new) = @_;

	if ($new) {
		# We could leave the old reference in the cache but
		# I am not sure that it is safe.
		delete $Cache{$self->_url};

		$self->_url($new);
		$self->updateCaches();
	}

	return $self->_url;
}


# Calling conventions:
# class->new($url)
# class->new($url, %attributes)
# class->new(%attributes) -- 'url' attribute in %attributes

sub new {
	my $class  = shift;
	my $attributes = shift;

	my $url;

	if (ref $attributes ne 'HASH') {
		$url = $attributes;
		$attributes = shift || {};
		$attributes->{'url'} = $url;
	} else {
		$url = $attributes->{'url'};
	}

	if (!defined $url) {
		$log->error('No url!');
		return undef;
	}

	my $self = $class->SUPER::new;

	main::DEBUGLOG && $log->is_debug && $log->debug("$class, $url");
#	main::DEBUGLOG && $log->logBacktrace();

	$self->init_accessor(_url => $url, id => -int($self), secs => 0, stash => {}, _processors => {});
	$self->init_accessor(remote => Slim::Music::Info::isRemoteURL($url));
	$self->setAttributes($attributes);

	$self->updateCaches();

	return $self;
}

# Probably do not need all of these any more
my %localTagMapping = (
	artist                 => 'artistname',
	albumartist            => 'artistname',
	trackartist            => 'artistname',
	album                  => 'albumname',
	rate                   => 'samplerate',
	age                    => 'timestamp',
	ct                     => 'content_type',
	fs                     => 'filesize',
	comment                => '_comment',
	offset                 => 'audio_offset',
	size                   => 'audio_size',
	blockalign             => 'block_alignment',
	composer               => undef,
	conductor              => undef,
	band                   => undef,
	remote                 => undef,
);

my %availableTags;
my $separator;

sub setAttributes {
	my ($self, $attributes) = @_;

	%availableTags = map { $_ => 1 } @allAttributes unless keys %availableTags;

	main::DEBUGLOG && $log->is_debug && $log->debug($self->url . " => ", Data::Dump::dump($attributes));

	Slim::Schema::processReplayGainTags($attributes, $self->path);

	while (my($key, $value) = each %{$attributes}) {
		next if !defined $value; # XXX not sure about this
		$key = lc($key);
		$key = $localTagMapping{$key} if exists $localTagMapping{$key};
		next if !defined($key) || $key eq 'url';
		next unless $availableTags{$key};

		# some formats can return multiple values per key - join them
		if ( (ref $value || '') eq 'ARRAY' ) {
			if (!$separator) {
				my @splitList = split(/\s+/, ($prefs->get('splitList') || ''));
				$separator = ($splitList[0] || ';') . ' ';
			}
			# - but don't join if it's a comment - the 'comment' method handles this
			$value = join($separator, @$value) unless $key eq '_comment';
		}

		main::DEBUGLOG && $log->is_debug && defined $self->$key() && $self->$key() ne $value &&
			$log->debug("$key: ", $self->$key(), "=>$value");

		$self->$key($value);
	}
}

sub updateOrCreate {
	my ($class, $objOrUrl, $attributes) = @_;

	my $self;
	my $url;

	if (blessed($objOrUrl) && ($objOrUrl->isa(__PACKAGE__))) {
		$self = $objOrUrl;
		$url = $self->_url();
	} else {
		$url = $objOrUrl;
		$self = $class->fetchFromUrlCache($url);
	}

	main::DEBUGLOG && $log->is_debug && $log->debug($url);

	if ($self) {
		$self->setAttributes($attributes);
	} else {
		$self = $class->new($url, $attributes);
	}

	return $self;
}

sub updateCaches {
	my ($self, $noDiskCache) = @_;

	if ($self) {
		$Cache{$self->url} = $self;
		$idIndex{$self->id} = $self;
		$cache->set('rt_' . $self->id, $self->url, DISK_CACHE_TTL) unless $noDiskCache || main::SCANNER;
	}
}

sub fetchFromUrlCache {
	my ($class, $url) = @_;

	my $self = $Cache{$url};
	$self->updateCaches(1) if $self;

	return $self;
}

sub fetch {
	my ($class, $url, $playlist) = @_;

	my $self = $class->fetchFromUrlCache($url);

	if ($self && $playlist && !$self->isa('Slim::Schema::RemotePlaylist')) {
		main::DEBUGLOG && $log->is_debug && $log->debug("$url upcast to RemotePlaylist");
		bless $self, 'Slim::Schema::RemotePlaylist';
	}

	return $self;
}

sub fetchById {
	my ($class, $id) = @_;

	my $self = $idIndex{$id};

	# try to get the URL from the disk cache - might be needed for BMF of volatile tracks
	if (!main::SCANNER && !$self) {
		if (my $url = $cache->get('rt_' . $id)) {
			$self = $class->new($url);

			# map from old ID to new object
			if ($self) {
				$idIndex{$id} = $self;
				$cache->set('rt_' . $id, $url, DISK_CACHE_TTL);
			}
		}
	}

	return $self;
}

sub get {
	my ($self, $attribute) = @_;

	main::DEBUGLOG && $log->is_debug &&
		$log->debug($self->_url, ', ', $attribute, '->', $self->$attribute() || "* undefined value *");

	return($self->$attribute());
}

sub get_column {
	return get(@_);
}

sub prettyBitRate {
	my $self = shift;

	my $bitrate  = $self->bitrate;
	my $vbrScale = $self->vbr_scale;

	my $mode = defined $vbrScale ? 'VBR' : 'CBR';

	if ($bitrate) {
		return int ($bitrate/1000) . Slim::Utils::Strings::string('KBPS') . ' ' . $mode;
	}

	return 0;
}

sub duration {
	my $self = shift;

	my $secs = $self->secs;

	return sprintf('%s:%02s', int($secs / 60), $secs % 60) if defined $secs && $secs > 0;
}

*modificationTime = \&Slim::Schema::Track::modificationTime;
*addedTime = \&Slim::Schema::Track::addedTime;
*lastUpdated = \&Slim::Schema::Track::lastUpdated;
*buildModificationTime = \&Slim::Schema::Track::buildModificationTime;

sub coverid { $_[0]->id }

1;
