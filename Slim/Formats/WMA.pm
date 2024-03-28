package Slim::Formats::WMA;


# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Formats);

use Slim::Utils::Log;

use Audio::Scan;

my $sourcelog = logger('player.source');

my %tagMapping = (
	'Author'                => 'ARTIST',
	'Title'                 => 'TITLE',
	'WM/BeatsPerMinute'     => 'BPM',
	'WM/AlbumArtist'        => 'ALBUMARTIST',
	'WM/AlbumTitle'         => 'ALBUM',
	'WM/Composer'           => 'COMPOSER',
	'WM/Conductor'          => 'CONDUCTOR',
	'WM/Genre'              => 'GENRE',
	'WM/TrackNumber'        => 'TRACKNUM',
	'WM/PartOfACompilation' => 'COMPILATION',
	'compilation'           => 'COMPILATION', # Bug 16991
	'Compilation'           => 'COMPILATION', # Bug 16991
	'WM/IsCompilation'      => 'COMPILATION', # Bug 16991
	'Description'           => 'COMMENT',
	'replaygain_track_gain' => 'REPLAYGAIN_TRACK_GAIN',
	'replaygain_track_peak' => 'REPLAYGAIN_TRACK_PEAK',
	'replaygain_album_gain' => 'REPLAYGAIN_ALBUM_GAIN',
	'replaygain_album_peak' => 'REPLAYGAIN_ALBUM_PEAK',
	'WM/PartOfSet'          => 'DISC',
	'WM/ArtistSortOrder'    => 'ARTISTSORT',
	'WM/AlbumSortOrder'     => 'ALBUMSORT',
	'WM/Comments'           => 'COMMENT',
	'WM/Lyrics'             => 'LYRICS',
	'WM/Year'               => 'YEAR',
	'WM/Work'               => 'WORK',
	'WM/ContentGroupDescription' => 'GROUPING',
	'WM/SubTitle'            => 'SUBTITLE',

	'MusicBrainz/Album Artist Id' => 'MUSICBRAINZ_ALBUMARTIST_ID',
	'MusicBrainz/Album Id'        => 'MUSICBRAINZ_ALBUM_ID',
	'MusicBrainz/Album Status'    => 'MUSICBRAINZ_ALBUM_STATUS',
	'MusicBrainz/Album Type'      => 'RELEASETYPE',
	'MusicBrainz/Artist Id'       => 'MUSICBRAINZ_ARTIST_ID',
	'MusicBrainz/Track Id'        => 'MUSICBRAINZ_ID',
	'MusicBrainz/TRM Id'          => 'MUSICBRAINZ_TRM_ID',
);

sub getTag {
	my $class = shift;
	my $file  = shift || return {};

	my $s = Audio::Scan->scan($file);

	my $info = $s->{info};
	my $tags = $s->{tags};

	return unless $info->{song_length_ms};

	# Map tags onto Lyrion Music Server's preferred.
	while ( my ($old, $new) = each %tagMapping ) {
		if ( exists $tags->{$old} ) {
			$tags->{$new} = delete $tags->{$old};
		}
	}

	# Sometimes the BPM is not an integer so we try to convert.
	$tags->{BPM} = int($tags->{BPM}) if defined $tags->{BPM};

	# Add additional info
	my $stream = $info->{streams}->[0];

	$tags->{SIZE}	      = $info->{file_size};
	$tags->{SECS}	      = $info->{song_length_ms} / 1000;
	$tags->{RATE}	      = $stream->{samplerate};
	$tags->{SAMPLESIZE}   = $stream->{bits_per_sample};
	$tags->{BITRATE}      = $info->{max_bitrate};
	$tags->{DRM}          = $stream->{encrypted};
	$tags->{CHANNELS}     = $stream->{channels};
	$tags->{LOSSLESS}     = $info->{lossless};
	$tags->{STEREO}       = $tags->{CHANNELS} == 2 ? 1 : 0;
	$tags->{DLNA_PROFILE} = $info->{dlna_profile} || undef;

	if ( $tags->{IsVBR} ) {
		$tags->{VBR_SCALE} = 1;
	}

	if ( grep (/Professional/, map ($_->{'name'}, @{$info->{'codec_list'}})) ) {
		$tags->{CONTENT_TYPE} = 'wmap';
	} elsif ( $tags->{LOSSLESS} ) {
		$tags->{CONTENT_TYPE} = 'wmal';
	}

	# Flag if we have embedded cover art
	if ( my $pic = $tags->{'WM/Picture'} ) {
		if ( ref $pic eq 'ARRAY' ) {
			# multiple images, use image with lowest image_type value
			# In 'no artwork' mode, ARTWORK is the length
			$tags->{COVER_LENGTH} = $ENV{AUDIO_SCAN_NO_ARTWORK}
				? ( sort { $a->{image_type} <=> $b->{image_type} } @{$pic} )[0]->{image}
				: length( ( sort { $a->{image_type} <=> $b->{image_type} } @{$pic} )[0]->{image} );
		}
		else {
			$tags->{COVER_LENGTH} = $ENV{AUDIO_SCAN_NO_ARTWORK}
				? $pic->{image}
				: length( $pic->{image} );
		}
	}

	return $tags;
}

sub getCoverArt {
	my $class = shift;
	my $file  = shift || return undef;

	# Enable artwork in Audio::Scan
	local $ENV{AUDIO_SCAN_NO_ARTWORK} = 0;

	my $s = Audio::Scan->scan_tags($file);

	if ( my $pic = $s->{tags}->{'WM/Picture'} ) {
		if ( ref $pic eq 'ARRAY' ) {
			# return image with lowest image_type value
			return ( sort { $a->{image_type} <=> $b->{image_type} } @{$pic} )[0]->{image};
		}
		else {
			return $pic->{image};
		}
	}

	return;
}

sub getInitialAudioBlock {
	my ($class, $fh) = @_;

	open my $localFh, '<&=', $fh;

	seek $localFh, 0, 0;

	my $s = Audio::Scan->scan_fh( asf => $localFh );

	main::DEBUGLOG && $sourcelog->is_debug && $sourcelog->debug( 'Reading initial audio block: length ' . $s->{info}->{audio_offset} );

	seek $localFh, 0, 0;
	read $localFh, my $buffer, $s->{info}->{audio_offset};

	close $localFh;

	return $buffer;
}

sub findFrameBoundaries {
	my ($class, $fh, $offset, $time) = @_;

	if (!defined $fh || !defined $time) {
		return 0;
	}

	return Audio::Scan->find_frame_fh( asf => $fh, int($time * 1000) );
}

sub canSeek { 1 }

1;
