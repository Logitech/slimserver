package Slim::Utils::ImageResizer;

use strict;

use File::Spec::Functions qw(catdir);
use Scalar::Util qw(blessed);

use Slim::Utils::ArtworkCache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

# UNIX domain socket for optional artwork resizing daemon, if this is
# present we will use async artwork resizing via the external daemon
use constant SOCKET_PATH    => '/tmp/sbs_artwork';
use constant SOCKET_TIMEOUT => 15;

my $prefs = preferences('server');
my $log   = logger('artwork');

my ($gdresizein, $gdresizeout, $gdresizeproc);

sub resize {
	my ($class, $file, $cachekey, $specs, $callback) = @_;
	
	my $isDebug = main::DEBUGLOG && $log->is_debug;
	
	# Check for callback, and that the gdresized daemon running and read/writable
	my $hasDaemon = $callback && !main::ISWINDOWS && -r SOCKET_PATH && -w _;
	
	if ($hasDaemon) {
		require AnyEvent::Socket;
		require AnyEvent::Handle;
		
		# Get cache root for passing to daemon
		my $cacheroot = catdir(
			$prefs->get('librarycachedir'),
			'ArtworkCache',
		);
		
		main::DEBUGLOG && $isDebug && $log->debug("Using gdresized daemon to resize");
		
		# Daemon available, do an async resize
		AnyEvent::Socket::tcp_connect( 'unix/', SOCKET_PATH, sub {
			my $fh = shift || do {
				main::DEBUGLOG && $isDebug && $log->debug("daemon failed to connect: $!");
				
				# Fallback to resizing the old way
				sync_resize($file, $cachekey, $specs, $callback);
				
				return;
			};
			
			my $handle;
			
			# Timer in case daemon craps out
			my $timeout = sub {
				main::DEBUGLOG && $isDebug && $log->debug("daemon timed out");
				
				$handle && $handle->destroy;
				
				# Fallback to resizing the old way
				sync_resize($file, $cachekey, $specs, $callback);
			};
			Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + SOCKET_TIMEOUT, $timeout );
			
			$handle = AnyEvent::Handle->new(
				fh       => $fh,
				on_read  => sub {},
				on_eof   => undef,
				on_error => sub {
					my $result = delete $_[0]->{rbuf};
					
					main::DEBUGLOG && $isDebug && $log->debug("daemon result: $result");
					
					$_[0]->destroy;
					
					Slim::Utils::Timers::killTimers(undef, $timeout);
					
					$callback && $callback->();
				},
			);
			
			$handle->push_write( pack('Z*Z*Z*Z*', $file, $specs, $cacheroot, $cachekey) . "\015\012" );
		}, sub {
			# prepare callback, used to set the timeout
			return SOCKET_TIMEOUT;
		} );
	}
	else {
		# No daemon, resize synchronously in-process
		sync_resize($file, $cachekey, $specs, $callback);
	}
}

sub sync_resize {
	my ( $file, $cachekey, $specs, $callback ) = @_;
	
	require Slim::Utils::GDResizer;
	
	my $isDebug = main::DEBUGLOG && $log->is_debug;
	
	my @spec = split(',', $specs);
	eval {
		Slim::Utils::GDResizer->gdresize(
			file      => $file,
			spec      => \@spec,
			cache     => Slim::Utils::ArtworkCache->new(),
			cachekey  => $cachekey,
			debug     => $isDebug,
			faster    => !$prefs->get('resampleArtwork'),
		);
	};
	
	if ( main::DEBUGLOG && $isDebug && $@ ) {
		$log->error("Error resizing $file: $@");
	}
	
	$callback && $callback->();
}

1;
