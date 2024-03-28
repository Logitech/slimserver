package Slim::Formats::Ogg;


# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Formats::Ogg

=head1 SYNOPSIS

my $tags = Slim::Formats::Ogg->getTag( $filename );

=head1 DESCRIPTION

Read tags & metadata embedded in Ogg Vorbis files.

=head1 METHODS

=cut

use strict;
use base qw(Slim::Formats);

use Fcntl qw(:seek);
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Audio::Scan;

my $log       = logger('scan.scanner');
my $sourcelog = logger('player.source');

my %tagMapping = (
	'TRACKNUMBER'               => 'TRACKNUM',
	'DISCNUMBER'                => 'DISC',
	'URL'                       => 'URLTAG',
	'BPM'                       => 'BPM',
	'MUSICBRAINZ_SORTNAME'      => 'ARTISTSORT',
	'MUSICBRAINZ_ALBUMARTIST'   => 'ALBUMARTIST',
	'MUSICBRAINZ_ALBUMARTISTID' => 'MUSICBRAINZ_ALBUMARTIST_ID',
	'MUSICBRAINZ_ALBUMID'       => 'MUSICBRAINZ_ALBUM_ID',
	'MUSICBRAINZ_ALBUMSTATUS'   => 'MUSICBRAINZ_ALBUM_STATUS',
	'MUSICBRAINZ_ALBUMTYPE'     => 'RELEASETYPE',               # https://picard-docs.musicbrainz.org/en/appendices/tag_mapping.html#id32
	'MUSICBRAINZ_ALBUM_TYPE'    => 'RELEASETYPE',
	'MUSICBRAINZ_ARTISTID'      => 'MUSICBRAINZ_ARTIST_ID',
	'MUSICBRAINZ_TRACKID'       => 'MUSICBRAINZ_ID',
	'MUSICBRAINZ_TRMID'         => 'MUSICBRAINZ_TRM_ID',
	'DESCRIPTION'               => 'COMMENT',

	# J.River once again.. can't these people use existing standards?
	'REPLAY GAIN'               => 'REPLAYGAIN_TRACK_GAIN',
	'PEAK LEVEL'                => 'REPLAYGAIN_TRACK_PEAK',
	'DISC #'                    => 'DISC',
	'ALBUM ARTIST'              => 'ALBUMARTIST',

	# for dBpoweramp CD Ripper
	'TOTALDISCS'                => 'DISCC',
);

=head2 getTag( $filename )

Extract and return audio information & any embedded metadata found.

=cut

sub getTag {
	my $class = shift;
	my $file  = shift || return {};

	my $s = Audio::Scan->scan($file);
	
	my $info = $s->{info};
	my $tags = $s->{tags};

	return unless $info->{song_length_ms};

	# Use Formats::FLAC for OggFlac and force the content type
	if ($s->{info}->{ogg_type} eq 'flac') {
		Slim::Formats->loadTagFormatForType('flc');
		return (Slim::Formats::FLAC->_getStandardTag($s), 'ogf');
	}

	# Map tags
	while ( my ($old, $new) = each %tagMapping ) {

		if ( exists $tags->{$old} ) {
			$tags->{$new} = delete $tags->{$old};
		}
	}

	# Special handling for DATE tags
	# Parse the date down to just the year, for compatibility with other formats
	if (defined $tags->{DATE} && !defined $tags->{YEAR}) {
		($tags->{YEAR} = $tags->{DATE}) =~ s/.*(\d\d\d\d).*/$1/;
	}

	# Sometimes the BPM is not an integer so we try to convert.
	$tags->{BPM} = int($tags->{BPM}) if defined $tags->{BPM};

	# Add additional info
	$tags->{SIZE}	  = $info->{file_size};
	$tags->{SECS}	  = $info->{song_length_ms} / 1000;
	$tags->{BITRATE}  = $info->{bitrate_average} || $info->{bitrate_nominal};
	$tags->{STEREO}   = $info->{channels} == 2 ? 1 : 0;
	$tags->{CHANNELS} = $info->{channels};
	$tags->{RATE}	  = $info->{samplerate};

	if ( defined $info->{bitrate_upper} && defined $info->{bitrate_lower} ) {
		if ( $info->{bitrate_upper} != $info->{bitrate_lower} ) {
			$tags->{VBR_SCALE} = 1;
		}
		else {
			$tags->{VBR_SCALE} = 0;
		}
	}
	else {
		$tags->{VBR_SCALE} = 0;
	}

	$tags->{OFFSET} = 0; # the header is an important part of the file. don't skip it

	# Read cover art if available
	if ( $tags->{ALLPICTURES} ) {
		my $pic;

		my @allpics = sort { $a->{picture_type} <=> $b->{picture_type} }
			@{ $tags->{ALLPICTURES} };

		if ( my @frontcover = grep ( $_->{picture_type} == 3, @allpics ) ) {
			# in case of many type 3 (front cover) just use the first one
			$pic = $frontcover[0]->{image_data};
		}
		else {
			# fall back to use lowest type image found
			$pic = $allpics[0]->{image_data};
		}

		# In 'no artwork' mode, ARTWORK is the length
		if ( $ENV{AUDIO_SCAN_NO_ARTWORK} ) {
			$tags->{COVER_LENGTH} = $pic;
		}
		else {
			$tags->{COVER_LENGTH} = length($pic);
		}
	}

	return $tags;
}

=head2 getCoverArt( $filename )

Extract and return cover image from the file.

=cut

sub getCoverArt {
	my $class = shift;
	my $file  = shift || return undef;

	# Enable artwork in Audio::Scan
	local $ENV{AUDIO_SCAN_NO_ARTWORK} = 0;

	my $s = Audio::Scan->scan_tags($file);
	my $tags = $s->{tags};

	# Standard picture block, try to find the front cover first
	if ( $tags->{ALLPICTURES} ) {
		my @allpics = sort { $a->{picture_type} <=> $b->{picture_type} }
			@{ $tags->{ALLPICTURES} };

		if ( my @frontcover = grep ( $_->{picture_type} == 3, @allpics ) ) {
			# in case of many type 3 (front cover) just use the first one
			return $frontcover[0]->{image_data};
		}
		else {
			# fall back to use lowest type image found
			return $allpics[0]->{image_data};
		}
	}

	return;
}

=head2 scanBitrate( $fh )

Scans a file and returns just the bitrate and VBR setting.  This is used
to determine the bitrate for remote streams.  This method is not very accurate
for Ogg files because we only know the nominal bitrate value, not the actual average
bitrate.

=cut

sub scanBitrate {
	my $class = shift;
	my $fh    = shift;
	my $url   = shift;

	my $isDebug = $log->is_debug;

	local $ENV{AUDIO_SCAN_NO_ARTWORK} = 0;

	seek $fh, 0, 0;

	my $s = Audio::Scan->scan_fh( ogg => $fh );

	if ( !$s->{info}->{audio_offset} ) {

		logWarning('Unable to parse Ogg stream');

		return (-1, undef);
	}

	my $info = $s->{info};
	my $tags = $s->{tags};

	# Save tag data if available
	if ( my $title = $tags->{TITLE} ) {
		# XXX: Schema ignores ARTIST, ALBUM, YEAR, and GENRE for remote URLs
		# so we have to format our title info manually.
		my $track = Slim::Schema->updateOrCreate( {
			url        => $url,
			attributes => {
				TITLE => $title,
			},
		} );

		main::DEBUGLOG && $isDebug && $log->debug("Read Ogg tags from stream: " . Data::Dump::dump($tags));

		$title .= ' ' . string('BY') . ' ' . $tags->{ARTIST} if $tags->{ARTIST};
		$title .= ' ' . string('FROM') . ' ' . $tags->{ALBUM} if $tags->{ALBUM};

		Slim::Music::Info::setCurrentTitle( $url, $title );

		# Save artwork if found
		# Read cover art if available
		if ( $tags->{ALLPICTURES} ) {
			my $coverart;
			my $mime;

			my @allpics = sort { $a->{picture_type} <=> $b->{picture_type} }
				@{ $tags->{ALLPICTURES} };

			if ( my @frontcover = grep ( $_->{picture_type} == 3, @allpics ) ) {
				# in case of many type 3 (front cover) just use the first one
				$coverart = $frontcover[0]->{image_data};
				$mime     = $frontcover[0]->{mime_type};
			}
			else {
				# fall back to use lowest type image found
				$coverart = $allpics[0]->{image_data};
				$mime     = $allpics[0]->{mime_type};
			}

			$track->cover( length($coverart) );
			$track->update;

			my $data = {
				image => $coverart,
				type  => $tags->{COVERARTMIME} || $mime,
			};

			my $cache = Slim::Utils::Cache->new();
			$cache->set( "cover_$url", $data, 86400 * 7 );

			main::DEBUGLOG && $isDebug && $log->debug( 'Found embedded cover art, saving for ' . $track->url );
		}
	}

	my $vbr = 0;

	if ( defined $info->{bitrate_upper} && defined $info->{bitrate_lower} ) {
		if ( $info->{bitrate_upper} != $info->{bitrate_lower} ) {
			$vbr = 1;
		}
	}

	if ( my $bitrate = ( $info->{bitrate_average} || $info->{bitrate_nominal} ) ) {

		main::DEBUGLOG && $isDebug && $log->debug("Found bitrate header: $bitrate kbps " . ( $vbr ? 'VBR' : 'CBR' ));

		return ( $bitrate, $vbr );
	}

	logWarning("Unable to read bitrate from stream!");

	return (-1, undef);
}

sub getInitialAudioBlock {
	my ($class, $fh) = @_;

	open my $localFh, '<&=', $fh;

	seek $localFh, 0, 0;

	my $s = Audio::Scan->scan_fh( ogg => $localFh );

	main::DEBUGLOG && $sourcelog->is_debug && $sourcelog->debug( 'Reading initial audio block: length ' . $s->{info}->{audio_offset} );

	seek $localFh, 0, 0;
	read $localFh, my $buffer, $s->{info}->{audio_offset};

	close $localFh;

	return $buffer;
}

=head2 findFrameBoundaries( $fh, $offset, $time )

Seeks to the Ogg block containing the sample at $time.

The only caller is L<Slim::Player::Source> at this time.

=cut

sub findFrameBoundaries {
	my ( $class, $fh, $offset, $time ) = @_;

	if ( !defined $fh || !defined $time ) {
		return 0;
	}

	return Audio::Scan->find_frame_fh( ogg => $fh, int($time * 1000) );
}

sub canSeek { 1 }

1;
