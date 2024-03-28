package Slim::Formats::Movie;


# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Formats);
use Fcntl qw(:seek SEEK_SET);

use Audio::Scan;

use Slim::Formats::MP3;
use Slim::Utils::Log;
use Slim::Utils::SoundCheck;

my %tagMapping = (
	AART => 'ALBUMARTIST',	# bug 10724 - support aART as Album Artist
	ALB  => 'ALBUM',
	ART  => 'ARTIST',
	CMT  => 'COMMENT',
	COVR => 'ARTWORK',
	CON  => 'CONDUCTOR',
	CPIL => 'COMPILATION',
	DAY  => 'YEAR',
	GNRE => 'GENRE',
	GEN  => 'GENRE',
	LYR  => 'LYRICS',
	NAM  => 'TITLE',
	SOAA => 'ALBUMARTISTSORT',
	SOAL => 'ALBUMSORT',
	SOAR => 'ARTISTSORT',
	SOCO => 'COMPOSERSORT',
	SONM => 'TITLESORT',
	TMPO => 'BPM',
	TRKN => 'TRACKNUM',
	WRT  => 'COMPOSER',
	WRK  => 'WORK',
	GRP  => 'GROUPING',
	'----:com.apple.iTunes:SUBTITLE' => 'SUBTITLE',	

	'MusicBrainz Album Id'     => 'MUSICBRAINZ_ALBUM_ID',
	'MusicBrainz Album Type'   => 'RELEASETYPE',
	'MusicBrainz Artist Id'    => 'MUSICBRAINZ_ARTIST_ID',
	'MusicBrainz Album Artist' => 'ALBUMARTIST',
	'MusicBrainz Album Artist Id' => 'MUSICBRAINZ_ALBUMARTIST_ID',
	'MusicBrainz Track Id'     => 'MUSICBRAINZ_ID',
	'MusicBrainz Sortname'     => 'ARTISTSORT',
	'MusicBrainz Album Status' => 'MUSICBRAINZ_ALBUM_STATUS',
);

sub getTag {
	my $class = shift;
	my $file  = shift || return {};

	my $s = Audio::Scan->scan( $file );

	my $info = $s->{info};
	my $tags = $s->{tags};

	return unless $info->{song_length_ms};

	# skip files with video tracks
	for my $track ( @{ $info->{tracks} } ) {
		return if exists $track->{width};
	}

	# map the existing tag names to the expected tag names
	$class->_doTagMapping($tags);

	$tags->{OFFSET}       = 0;
	$tags->{RATE}         = $info->{samplerate};
	$tags->{SIZE}         = $info->{file_size};
	$tags->{SECS}         = $info->{song_length_ms} / 1000;
	$tags->{BITRATE}      = $info->{avg_bitrate};
	$tags->{DLNA_PROFILE} = $info->{dlna_profile} || undef;
	$tags->{LEADING_MDAT} = $info->{leading_mdat} || undef;

	if ( my $track = $info->{tracks}->[0] ) {
		# MP4 file
		$tags->{SAMPLESIZE} = $track->{bits_per_sample};
		$tags->{CHANNELS}   = $track->{channels};

		# If encoding is alac, the file is lossless.
		if ( $track->{encoding} && $track->{encoding} eq 'alac' ) {
			$tags->{LOSSLESS}     = 1;
			$tags->{VBR_SCALE}    = 1;
			$tags->{CONTENT_TYPE} = 'alc';
		}
		elsif ( $track->{encoding} && $track->{encoding} eq 'drms' ) {
			$tags->{DRM} = 1;
		}

		# Check for HD-AAC file, if the file has 2 tracks and AOTs of 2/37
		if ( defined $track->{audio_object_type} && (my $track2 = $info->{tracks}->[1]) ) {
			if ( $track->{audio_object_type} == 2 && $track2->{audio_object_type} == 37 ) {
				$tags->{LOSSLESS}     = 1;
				$tags->{VBR_SCALE}    = 1;
				$tags->{SAMPLESIZE}   = $track2->{bits_per_sample};
				$tags->{CONTENT_TYPE} = 'sls';
			}
		}
	}
	elsif ( $info->{bitrate} ) {
		# ADTS file
		$tags->{OFFSET}   = $info->{audio_offset}; # ID3v2 tags may be present
		$tags->{BITRATE}  = $info->{bitrate};
		$tags->{CHANNELS} = $info->{channels};

		if ( $info->{id3_version} ) {
			$tags->{TAGVERSION} = $info->{id3_version};

			Slim::Formats::MP3->doTagMapping($tags);
		}
	}

	return $tags;
}

sub getCoverArt {
	my $class = shift;
	my $file  = shift;

	# Enable artwork in Audio::Scan
	local $ENV{AUDIO_SCAN_NO_ARTWORK} = 0;

	my $s = Audio::Scan->scan_tags($file);

	return $s->{tags}->{COVR};
}

sub _doTagMapping {
	my ($class, $tags) = @_;

	# map the existing tag names to the expected tag names
	while ( my ($old, $new) = each %tagMapping ) {
		foreach ($old, uc($old)) {
			if ( exists $tags->{$_} ) {
				$tags->{$new} = delete $tags->{$_};
				last;
			}
		}
	}

	# Special handling for DATE tags
	# Parse the date down to just the year, for compatibility with other formats
	if ( defined $tags->{YEAR} ) {
		$tags->{YEAR} =~ s/.*(\d\d\d\d).*/$1/;
	}

	# Unroll the disc info.
	if ( $tags->{DISK} ) {
		($tags->{DISC}, $tags->{DISCC}) = split /\//, delete $tags->{DISK};
	}

	# Look for iTunes SoundCheck data, unless we have a TXXX track gain tag
	if ( !$tags->{REPLAYGAIN_TRACK_GAIN} ) {
		if ( $tags->{ITUNNORM} ) {
			$tags->{REPLAYGAIN_TRACK_GAIN} = Slim::Utils::SoundCheck::normStringTodB( delete $tags->{ITUNNORM} );
		}
	}

	# Flag if we have embedded cover art
	if ( $tags->{ARTWORK} ) {
		if ( $ENV{AUDIO_SCAN_NO_ARTWORK} ) {
			# In 'no artwork' mode, ARTWORK is the length
			$tags->{COVER_LENGTH} = $tags->{ARTWORK};
		}
		else {
			$tags->{COVER_LENGTH} = length( $tags->{ARTWORK} );
		}
	}
}

# never used for ADTS because there is no initial block
sub volatileInitialAudioBlock { 1 }

sub getInitialAudioBlock {
	my ($class, $fh, $track, $time) = @_;

	my $sourcelog = logger('player.source');

	# When playing the start of a virtual cue sheet track, findFrameBoundaries will not have been called
	if ( !exists ${*$fh}{_mp4_seek_header} && $track->url =~ /#([^-]+)-([^-]+)$/ ) {
		$class->findFrameBoundaries( $fh, undef, $1 );
	}

	# no seek header => ADTS file and no need of InitialAudioBlock
	return undef if (!exists ${*$fh}{_mp4_seek_header});

	main::INFOLOG && $sourcelog->is_info && $sourcelog->info(
	    'Reading initial audio block: length ' . length( ${ ${*$fh}{_mp4_seek_header} } )
	);

	return ${ delete ${*$fh}{_mp4_seek_header} };
}

sub findFrameBoundaries {
	my ($class, $fh, $offset, $time) = @_;

	if (!defined $fh || !defined $time) {
		return 0;
	}

	# Need a localFh to have own seek pointer
	open(my $localFh, '<&=', $fh);
	$localFh->seek(0, SEEK_SET);

	my $info = Audio::Scan->find_frame_fh_return_info( mp4 => $localFh, int($time * 1000) );

	if ($info->{tracks}->[0]) {
		# Since getInitialAudioBlock will be called right away, stash the new seek header so
		# we don't have to scan again
		${*$fh}{_mp4_seek_header} = \($info->{seek_header});
		return $info->{seek_offset};
	}
	else {
		# ADTS, need to scan bitrate
		seek($localFh, 0, SEEK_SET);
		my $info = Audio::Scan->scan_fh( aac => $localFh )->{info} || {};

		$offset = defined $time ?
		          int($info->{bitrate} * $time / 8) + $info->{audio_offset} :
				  abs($offset);

		# an ADTS frame is max 8191 bytes, so we'll capture one for sure
		seek($localFh, $offset, SEEK_SET);
		read($localFh, my $buffer, 16384);

		# iterate in buffer till we find an ADTS frame... or not
		for (my $pos = 0; ($pos = index($buffer, "\xFF\xF1", $pos)) >= 0; $pos += 2) {
			my $length = (unpack('N', substr($buffer, $pos + 3, 4)) >> 13) & 0x1fff;
			return $offset + $pos if substr($buffer, $pos + $length, 2) eq "\xFF\xF1";
		}
	}

	# nothing found
	return -1;
}

sub canSeek { 1 }

sub parseStream {
	my ( $class, $dataref, $args ) = @_;
	return -1 unless defined $$dataref;

	# stitch new data to existing buf and init parser if needed
	$args->{_scanbuf} .= $$dataref;
	$args->{_need} ||= 8;
	$args->{_offset} ||= 0;

	my $len = length($$dataref);
	my $offset = $args->{_offset};
	my $log = logger('player.streaming');

	while (length($args->{_scanbuf}) > $args->{_offset} + $args->{_need} + 8) {
		$args->{_atom} = substr($args->{_scanbuf}, $offset+4, 4);
		$args->{_need} = unpack('N', substr($args->{_scanbuf}, $offset, 4));
		$args->{_offset} = $args->{"_$args->{_atom}_"} = $offset;

		# a bit of sanity check
		if ($offset == 0 && $args->{_atom} ne 'ftyp') {
			$log->warn("no header! this is supposed to be a mp4 track");
			return 0;
		}

		# if there is a stco, the first entry is the audio_offset
		if ($args->{_atom} eq 'stco') {
			$args->{_audio_offset} = unpack('N', substr($args->{_scanbuf}, $offset+16, 4));
			main::DEBUGLOG && $log->is_debug && $log->debug("found audio offset with stco $args->{_audio_offset}");
		}

		# need to dive into atoms to find optional stco
		$offset += ($args->{_atom} !~ /^(moov|trak|mdia|minf|stbl)$/) ? $args->{_need} : 8;

		main::DEBUGLOG && $log->is_debug && $log->debug("atom $args->{_atom} at $args->{_offset} of size $args->{_need}");

		# mdat reached = audio offset & size acquired
		if ($args->{_atom} eq 'mdat') {
			$args->{_audio_size} = $args->{_need};
			last;
		}
	}

	return -1 unless $args->{_mdat_};

	# now make sure we have acquired a full moov atom
	if (!$args->{_moov_}) {
		# no 'moov' found but EoF
		if (!$len) {
			$log->warn("no 'moov' found before EOF => track probably not playable");
			return 0;
		}

		# already waiting for bottom 'moov', we need more
		return -1 if $args->{_range};

		# top 'moov' not found, need to seek beyond 'mdat'
		$args->{_range} = $offset;
		substr($args->{_scanbuf}, $args->{_offset}) = '';
		delete $args->{_need};
		return $offset;
	} elsif ($args->{_atom} eq 'moov' && $len) {
		return -1;
	}

	# finally got it, add 'moov' size it if was last atom
	substr($args->{_scanbuf}, $args->{_offset} + ($args->{_atom} eq 'moov' ? $args->{_need} : 0)) = '';

	# put at least 16 bytes after mdat or it confuses audio::scan (and header creation)
	my $fh = File::Temp->new( DIR => Slim::Utils::Misc::getTempDir);
	$fh->write($args->{_scanbuf} . pack('N', $args->{_audio_size}) . 'mdat' . ' ' x 16);
	$fh->seek(0, 0);

	my $info = Audio::Scan->scan_fh( mp4 => $fh )->{info};
	$info->{fh} = $fh;

	# audio offset from stco or mdat position, but audio_size needs adjustment
	$info->{audio_offset} = $args->{_audio_offset} || ($args->{_mdat_} + 8);
	$info->{audio_size} -= $info->{audio_offset} - $args->{_mdat_};

	# MPEG-4 audio = 64,  MPEG-4 ADTS main = 102, MPEG-4 ADTS Low Complexity = 103
	# MPEG-4 ADTS Scalable Sampling Rate = 104
	if ($info->{tracks}->[0] && $info->{tracks}->[0]->{audio_type} == 64) {
		$info->{processors} = { 'aac' => \&setADTSProcess };
	}

	return $info;
}

sub setADTSProcess {
	my ($bufref) = @_;
	my $pos;
	my $codec;
	my %atoms = (
		stsd => 16,
		mp4a => 36,
		meta => 12,
		moov => 8,
		trak => 8,
		mdia => 8,
		minf => 8,
		stbl => 8,
		utda => 8,
		ilst => 8,
	);

	while ($pos < length $$bufref) {
		my $len = unpack("N", substr($$bufref, $pos, 4));
		my $type = substr($$bufref, $pos + 4, 4);
		$pos += 8;

		last if $type eq 'mdat';

		if ($type eq 'esds') {
			my $offset = 4;
			last unless unpack("C", substr($$bufref, $pos + $offset++, 1)) == 0x03;
			my $data = unpack("C", substr($$bufref, $pos + $offset, 1));
			$offset += 3 if $data == 0x80 || $data == 0x81 || $data == 0xfe;
			$offset += 4;
			last unless unpack("C", substr($$bufref, $pos + $offset++, 1)) == 0x04;
			$data = unpack("C", substr($$bufref, $pos + $offset, 1));
			$offset += 3 if $data == 0x80 || $data == 0x81 || $data == 0xfe;
			$offset += 14;
			last unless unpack("C", substr($$bufref, $pos + $offset++, 1)) == 0x05;
			$data = unpack("C", substr($$bufref, $pos + $offset, 1));
			$offset += 3 if $data == 0x80 || $data == 0x81 || $data == 0xfe;
			$offset++;
			$data = unpack("N", substr($$bufref, $pos + $offset, 4));
			$codec->{freq_index} = ($data >> 23) & 0x0f;
			$codec->{channel_config} = ($data >> 19) & 0x0f;
			$codec->{object_type} = $data >> 27;
			$codec->{object_type} = ($data >> 10) & 0x1f if $codec->{object_type} == 5 || $codec->{object_type} == 29;
			$pos += $len - 8;
	} elsif ($type eq 'stsz') {
			my $offset = 4;
			$codec->{frame_size} = unpack("N", substr($$bufref, $pos + $offset, 4));
			if (!$codec->{frame_size}) {
				$offset += 4;
				$codec->{frames}= [];
				$codec->{entries} = unpack("N", substr($$bufref, $pos + $offset, 4));
				$offset += 4;
				$codec->{frames} = [ unpack("N[$codec->{entries}]", substr($$bufref, $pos + $offset)) ];
				if ($codec->{entries} != scalar @{$codec->{frames}}) {
					logger('player.source')->warn("inconsistent stsz entries $codec->{entries} vs ", scalar @{$codec->{frames}});
					$codec->{entries} = scalar @{$codec->{frames}};
				}
			}
			$pos += $len - 8;
		} else {
			$pos += ($atoms{$type} || $len) - 8;
		}

		last if ($codec->{frame_size} || $codec->{entries}) && $codec->{channel_config};
	}

	# don't want to send a header when doing AAC demuxs
	$$bufref = '';

	# use a closure to hold context
	return sub {
		return extractADTS($codec, @_);
	}
}

sub extractADTS {
	my ($codec, undef, $chunk_size, $offset) = @_;
	my $consumed = 0;
	my @ADTSHeader = (0xFF,0xF1,0,0,0,0,0xFC);

	$codec->{inbuf} .= substr($_[1], $offset);
	substr($_[1], $offset) = '';

	while ($codec->{frame_size} || $codec->{frame_index} < $codec->{entries}) {
		my $frame_size = $codec->{frame_size} || $codec->{frames}->[$codec->{frame_index}];
		last if $frame_size + $consumed > length($codec->{inbuf}) || length($_[1]) + $frame_size + 7 > $chunk_size;

		$ADTSHeader[2] = (((($codec->{object_type} & 0x3) - 1)  << 6)   + ($codec->{freq_index} << 2) + ($codec->{channel_config} >> 2));
		$ADTSHeader[3] = ((($codec->{channel_config} & 0x3) << 6) + (($frame_size + 7) >> 11));
		$ADTSHeader[4] = ( (($frame_size + 7) & 0x7ff) >> 3);
		$ADTSHeader[5] = (((($frame_size + 7) & 7) << 5) + 0x1f) ;

		$_[1] .= pack("CCCCCCC", @ADTSHeader) . substr($codec->{inbuf}, $consumed, $frame_size);

		$codec->{frame_index}++;
		$consumed += $frame_size;
	}

	substr($codec->{inbuf}, 0, $consumed, '');
	return length $codec->{inbuf};
}

# AAAAAAAA AAAABCCD EEFFFFGH HHIJKLMM MMMMMMMM MMMOOOOO OOOOOOPP
#
# Header consists of 7 bytes without CRC.
#
# Letter	Length (bits)	Description
# A	12	syncword 0xFFF, all bits must be 1
# B	1	MPEG Version: 0 for MPEG-4, 1 for MPEG-2
# C	2	Layer: always 0
# D	1	set to 1 as there is no CRC
# E	2	profile, the MPEG-4 Audio Object Type minus 1
# F	4	MPEG-4 Sampling Frequency Index (15 is forbidden)
# G	1	private bit, guaranteed never to be used by MPEG, set to 0 when encoding, ignore when decoding
# H	3	MPEG-4 Channel Configuration (in the case of 0, the channel configuration is sent via an inband PCE)
# I	1	originality, set to 0 when encoding, ignore when decoding
# J	1	home, set to 0 when encoding, ignore when decoding
# K	1	copyrighted id bit, the next bit of a centrally registered copyright identifier, set to 0 when encoding, ignore when decoding
# L	1	copyright id start, signals that this frame's copyright id bit is the first bit of the copyright id, set to 0 when encoding, ignore when decoding
# M	13	frame length, this value must include 7 bytes of header
# O	11	Buffer fullness
# P	2	Number of AAC frames (RDBs) in ADTS frame minus 1, for maximum compatibility always use 1 AAC frame per ADTS frame
#
# ISO 14496 Part 3 Table 1.13
#
# A: Profile (2=LC, 5=SBR, 29=PS), R: Core SampleRate, M: Main SampleRate,
# C: Channels, X: Extensions, S=???, T=???, E=extension bit
#
# AOT=2      AOT=5|29   AOT=2 (extended)
# AAAA ARRR  AAAA ARRR  AAAA ARRR
# RCCC CXXX  RCCC CMMM  RCCC CXXX
#            MPPP PP    SSSS SSSS
#                       SSST TTTT
#                       ERRR R


1;
