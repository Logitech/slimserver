package Slim::Control::Request;

# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# This class implements a generic request mechanism for Lyrion Music Server.
# More documentation is provided below the table of commands & queries

=head1 NAME

Slim::Control::Request

=head1 DESCRIPTION

This class implements a generic request mechanism for Lyrion Music Server.

The general mechansim is to create a Request object and execute it. There is
an option of specifying a callback function, to be called once the request is
executed. In addition, external code can be notified of command execution (see
NOTIFICATIONS below).

Function "Slim::Control::Request::executeRequest" accepts the usual parameters
of client, command array and callback params, and returns the request object.

my $request = Slim::Control::Request::executeRequest($client, ['stop']);

=cut

#####################################################################################################################################################################

=head1 COMMANDS & QUERIES LIST

 This table lists all supported commands and queries with their parameters.

 C     P0             P1                          P2                          P3               P4       P5

=cut

#####################################################################################################################################################################

=head2 GENERAL

 N    debug           <debugflag>                 <OFF|FATAL|ERROR|WARN|INFO|DEBUG|?|>
 N    pref            <prefname>                  <prefvalue|?>
 N    version         ?
 N    stopserver

=head2 DATABASE

 N    rescan          <|playlists|?>
 N    rescanprogress  <tagged parameters>
 N    wipecache
 N    pragma          <pragma>

 N    albums          <startindex>                <numitems>                  <tagged parameters>
 N    artists         <startindex>                <numitems>                  <tagged parameters>
 N    genres          <startindex>                <numitems>                  <tagged parameters>
 N    info            total                       genres|artists|albums|songs ?
 N    songinfo        <startindex>                <numitems>                  <tagged parameters> (DEPRECATED)
 N    titles          <startindex>                <numitems>                  <tagged parameters>
 N    years           <startindex>                <numitems>                  <tagged parameters>
 N    musicfolder     <startindex>                <numitems>                  <tagged parameters>

 N    playlists       <startindex>                <numitems>                  <tagged parameters>
 N    playlists       tracks                      <startindex>                <numitems>       <tagged parameters>
 N    playlists       edit                        <tagged parameters>
 N    playlists       new                         <tagged parameters>
 N    artwork         <tagged parameters>

 N    rating          <item>                      <rating>
 N    rating          <item>                      ?

=head2 PLAYERS


 Y    alarm           <tagged parameters>
 Y    button          <buttoncode>
 Y    connect         <ip>
 Y    client          forget
 Y    display         <line1>                     <line2>                       <duration>
 Y    ir              <ircode>                    <time>
 Y    mixer           volume                      <0..100|-100..+100|?>
 Y    mixer           bass                        <0..100|-100..+100|?>
 Y    mixer           treble                      <0..100|-100..+100|?>
 Y    mixer           pitch                       <80..120|-100..+100|?>
 Y    mixer           muting                      <|?>
 Y    name            <newname|?>
 Y    playerpref      <prefname>                  <prefvalue|?>
 Y    power           <0|1|?|>
 Y    sleep           <0..n|?>
 Y    sync            <playerindex|playerid|-|?>
 Y    mode            ?
 Y    irenable        <0|1|?|>

 Y    alarms          <startindex>                <numitems>                  <tagged parameters>
 Y    signalstrength  ?
 Y    connected       ?
 Y    display         ?                           ?
 Y    displaynow      ?                           ?
 Y    displaystatus   <tagged parameters>
 Y    show
 N    player          count                       ?
 N    player          ip                          <index or ID>               ?
 N    player          id|address                  <index or ID>               ?
 N    player          name                        <index or ID>               ?
 N    player          model                       <index or ID>               ?
 N    player          isplayer                    <index or ID>               ?
 N    player          displaytype                 <index or ID>               ?
 N    players         <startindex>                <numitems>                  <tagged parameters>


=head2 PLAYLISTS

 Y    pause           <0|1|>                      <fadeInSecs> (only for resume)
 Y    play            <fadeInSecs>
 Y    playlist        add|append                  <item> (item can be a song, playlist or directory) <title> (override)
 Y    playlist        addalbum                    <genre>                     <artist>         <album>  <songtitle>
 Y    playlist        addtracks                   <searchterms>
 Y    playlist        clear
 Y    playlist        delete                      <index>
 Y    playlist        deletealbum                 <genre>                     <artist>         <album>  <songtitle>
 Y    playlist        deleteitem                  <item> (item can be a song, playlist or directory)
 Y    playlist        deletetracks                <searchterms>
 Y    playlist        index|jump                  <index|?>                   <fadeInSecs>     <0|1> (noplay)
 Y    playlist        insert|insertlist           <item> (item can be a song, playlist or directory)
 Y    playlist        insertalbum                 <genre>                     <artist>         <album>  <songtitle>
 Y    playlist        inserttracks                <searchterms>
 Y    playlist        loadalbum|playalbum         <genre>                     <artist>         <album>  <songtitle>
 Y    playlist        loadtracks                  <searchterms>
 Y    playlist        move                        <fromindex>                 <toindex>
 Y    playlist        play|load|resume            <item> (item can be a song, playlist or directory) <title> (override) <fadeInSecs>
 Y    playlist        playtracks                  <searchterms>
 Y    playlist        repeat                      <0|1|2|?|>
 Y    playlist        shuffle                     <0|1|2|?|>
 Y    playlist        save                        <name>
 Y    playlist        zap                         <index>
 Y    playlistcontrol <tagged parameters>
 Y    stop
 Y    time            <0..n|-n|+n|?>

 Y    artist          ?
 Y    album           ?
 Y    duration        ?
 Y    genre           ?
 Y    title           ?
 Y    path            ?
 Y    current_title   ?
 Y    remote          ?

 Y    playlist        tracks                      ?

 Y    playlist        genre                       <index>                     ?
 Y    playlist        artist                      <index>                     ?
 Y    playlist        album                       <index>                     ?
 Y    playlist        title                       <index>                     ?
 Y    playlist        duration                    <index>                     ?
 Y    playlist        path                        <index>                     ?
 Y    playlist        remote                      <index>                     ?

 Y    playlist        name                        ?
 Y    playlist        url                         ?
 Y    playlist        modified                    ?
 Y    playlist        playlistsinfo               <tagged parameters>

 COMPOUND

 N    serverstatus    <startindex>                <numitems>                  <tagged parameters>
 Y    status          <startindex>                <numitems>                  <tagged parameters>


 DEPRECATED (BUT STILL SUPPORTED)
 Y    mode            <play|pause|stop>
 Y    gototime        <0..n|-n|+n|?>
 N    playlisttracks  <startindex>                <numitems>                  <tagged parameters>


=head2 NOTIFICATION

 The following 'terms' are used for notifications

 Y    client          disconnect
 Y    client          new
 Y    client          reconnect
 Y    client          upgrade_firmware
 Y    playlist        load_done
 Y    playlist        newsong                     <current_title>
 Y    playlist        open                        <url>
 Y    playlist        sync
 Y    playlist        cant_open                   <url>                      <error>
 Y    playlist        pause                       <0|1>
 Y    playlist        stop
 N    rescan          done
 N    library         changed               	  <0|1>
 Y    unknownir       <ircode>                    <timestamp>
 N    prefset         <namespace>                 <prefname>                  <newvalue>
 Y    alarm           sound                       <id>
 Y    alarm           end                         <id>
 Y    alarm           snooze                      <id>
 Y    alarm           snooze_end                  <id>
 Y    newmetadata

=head2 PLUGINS

 Plugins can call addDispatch (see below) to add their own commands to this
 table.

=cut

#####################################################################################################################################################################

=head1 REQUESTS

 Requests are object that embodies all data related to performing an action or
 a query.

=head2 ** client ID **

   Requests store the client ID, if any, to which it applies
     my $clientid = $request->clientid();   # read
     $request->clientid($client->id());     # set

   Methods are provided for convenience using a client, in particular all
   executeXXXX calls
     my $client = $request->client();       # read
     $request->client($client);             # set

   Some requests require a client to operate. This is encoded in the
   request for error detection. These calls are unlikely to be useful to
   users of the class but mentioned here for completeness.
     if ($request->needClient()) { ...      # read
     $request->needClient(1);               # set

=head2 ** type **

   Requests are commands that do something or queries that change nothing but
   mainly return data. They are differentiated mainly for performance reasons,
   for example queries are NOT notified. These calls are unlikely to be useful
   to users of the class but mentioned here for completeness.
     if ($request->query()) {...            # read
     $request->query(1);                    # set

=head2 ** request name **

   For historical reasons, command names are composed of multiple terms, f.e.
   "playlist save" or "info total genres", represented as an array. This
   convention was kept, mainly because of the amount of code relying on it.
   The request name is therefore represented as an array, that you can access
   using the getRequest method
     $request->getRequest(0);               # read the first term f.e. "playlist"
     $request->getRequest(1);               # read 2nd term, f.e. "save"
     my $cnt = $request->getRequestCount(); # number of terms
     my $str = $request->getRequestString();# string of all terms, f.e. "playlist save"

   Normally, creating the request is performed through the execute calls or by
   calling new with an array that is parsed by the code here to match the
   available commands and automatically assign parameters. The following
   method is unlikely to be useful to users of this class, but is mentioned
   for completeness.
     $request->addRequest($term);           # add a term to the request

=head2 ** parameters **

   The parsing performed on the array names all parameters, positional or
   tagged. Positional parameters are assigned a name from the addDispatch table,
   and any extra parameters are added as "_pX", where X is the position in the
   array. Tagged parameters are named by their tags, obviously.
   As a consequence, users of the class only access parameter by name
     $request->getParam('_index');          # get the '_index' param
     $request->getParam('_p4');             # get the '_p4' param (auto named)
     $request->getParam('cmd');             # get a tagged param

   Here again, routines used to add parameters are normally not used
   by users of this class, but for completeness
     $request->addParamPos($value);         # adds positional parameter
     $request->addParam($key, $value);      # adds named parameter

=head2 ** results **

   Queries, but some commands as well, do add results to a request. Results
   are either single data points (f.e. how many elements where inserted) or
   loops (i.e. data for song 1, data being a list of single data point, data for
   song 2, etc).
   Results are named like parameters. Obviously results are only available
   once the request has been executed (without errors)
     my $data = $request->getResult('_value');
                                            # get a result

   There can be multiple loops in the results. Each loop is named and starts
   with a '@'.
     my $looped = $request->getResultLoop('@songs', 0, '_value');
                                            # get first '_value' result in
                                            # loop '@songs'


=head1 NOTIFICATIONS

 The Request mechanism can notify "subscriber" functions of successful
 command request execution (not of queries). Callback functions have a single
 parameter corresponding to the request object.
 Optionally, the subscribe routine accepts a filter, which limits calls to the
 subscriber callback to those requests matching the filter. The filter is
 in the form of an array ref containing arrays refs (one per dispatch level)
 containing lists of desirable commands (easier to code than explain, see
 examples below).
 Note that notifications are performed asynchronously from the corresponding
 requests. Notifications are queued and performed when time allows.

=head2 Example

 Slim::Control::Request::subscribe( \&myCallbackFunction,
                                     [['playlist']]);
 -> myCallbackFunction will be called for any command starting with 'playlist'
 in the table below ('playlist save', playlist loadtracks', etc).

 Slim::Control::Request::subscribe( \&myCallbackFunction,
				                      [['playlist'], ['save', 'clear']]);
 -> myCallbackFunction will be called for commands "playlist save" and
 "playlist clear", but not for "playlist loadtracks".

 In both cases, myCallbackFunction must be defined as:
 sub myCallbackFunction {
      my $request = shift;

      # do something useful here
      # use the methods of $request to find all information on the
      # request.

      my $client = $request->client();

      my $cmd = $request->getRequestString();

      main::INFOLOG && $log->info("myCallbackFunction called for cmd $cmd\n");
 }


=head1 WRITING COMMANDS & QUERIES, PLUGINS

=head2 This sections provides a rough guide to writing commands and queries.

 Plugins are welcomed to add their own commands to the dispatch table. The
 commands or queries are therefore automatically available in the CLI. Plugin
 authors shall document their commands and queries as they see fit. Plugins
 delivered with the server are documented in the cli API document.

=head2 Adding a command

 To add a command to the dispatch table, use the addDispatch method. If the
 method is part of the server itself, please add it to the init method below
 and update the comment table at the top of the document.
 In a plugin, call the method from your initPlugin subroutine.

  Slim::Control::Request::addDispatch([<TERMS>], [<DEFINITION>]);

 <TERMS> is a list of the name of the command or query AND positional
 parameters. (Strictly speaking, the function expects 2 array references).
 The name of the request can be one or more words, like "playlist clear" or
 "info total genres ?". They have to be array elements, so look like:

      addDispatch(['info', 'total', 'genres', '?'], ...

 The request mechanism uses the first array to match requests to definitions.
 There are 3 possibilities: '?' matches itself, but is not added as a param
 (the idea is that the result replaces it). Anything starting with '_' is a
 parameter: something can be provided to give it a value: it is added to the
 request as a named parameter. Anything else much match itself and is
 considered part of the request.
 Order matter we well: first request name, then named parameters, then ?.

       addDispatch(['playlist', 'artist', '_index', '?'], ...

   -> ['playlist', 'artist', 'whatever', '?'] OK
   -> ['playlist', 'artist', '33',       '?'] OK
   -> ['playlist', 'artist', '?']             NOK (missing param)
   -> ['playlist', 'artist', '33']            NOK (missing ?)


 The second array <DEFINITION> contains information about the request:
  array[0]: flag indicating if the request requires a client. If enabled,
            the request will not proceed if the client is invalid or undef.
  array[1]: flag indicating if the request is a query. If enabled, the request
            is not notified.
  array[2]: flag indicating if the request has tagged parameters (in the form
            'tag:value'. If enabled the request will look for them while
            parsing the input.
  array[3]: function reference. Please refer to Commands.pm and Queries.pm for
            examples.

 For updates or new server commands, the table format below is the preferred
 choice. In a plugin, the following form may be used:

        |requires Client
        |  |is a Query
        |  |  |has Tags
        |  |  |  |Function to call
        C  Q  T  F

   Slim::Control::Request::addDispatch(['can'],
       [0, 1, 0, \&canQuery]);

=head2 Grabbing a command

 Some plugins may require to replace or otherwise complete a built in command of
 the server (or a command added by another plugin that happened to load before).

 The addDispatch call will return the function pointer of any existing
 command it replaces. There is no check on the <DEFINITION> array.

 So for example, a plugin could replace the "volume" command with the
 following code example:

   my $original_func = addDispatch(['mixer', 'volume', '_newvalue'],
       [1, 0, 0, \&new_mixerVolumeCommand]);

 Please perform all relevant checks in the new function and check the
 original code for any twists to take into account, like synced players.
 Your code should either end up calling $request->setStatusDone OR call the
 original function, maybe after some parameter doctoring.

 The function dynamicAutoQuery() in Queries.pm is a good example of this
 technique.

=cut

use strict;

use Scalar::Util qw(blessed);
use Tie::IxHash;

use Slim::Control::Commands;
use Slim::Control::Queries;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(cstring);

our $dispatchDB = {};           # contains a multi-level hash pointing to
                                # params and functions to call for each command or query

our %listeners = ();            # contains the clients to the notification
                                # mechanism (internal to the server)

our %subscribers = ();          # contains the requests being subscribed to
                                # (generaly by external users/clients)

our @notificationQueue;         # contains the Requests waiting to be notified

my $listenerSuperRE = qr/::/;   # regexp to screen out request which no listeners are interested in
                                # (maintained by __updateListenerSuperRE, :: = won't match)

my $alwaysUseIxHashes = 0;      # global flag which is set when we need to use tied IxHashes
                                # this is set when a cli subscription is active

my $log = logger('control.command');

################################################################################
# Package methods
################################################################################
# These function are really package functions, i.e. to be called like
#  Slim::Control::Request::subscribe() ...

# adds standard commands and queries to the dispatch DB...
sub init {

######################################################################################################################################################################
#	                                                                                                    |requires Client
#	                                                                                                    |  |is a Query
#	                                                                                                    |  |  |has Tags
#	                                                                                                    |  |  |  |Function to call
#	              P0               P1                P2            P3             P4         P5         C  Q  T  F
######################################################################################################################################################################

	addDispatch(['abortscan'],                                                                         [0, 0, 0, \&Slim::Control::Commands::abortScanCommand]);
	addDispatch(['alarm',          '_cmd'],                                                            [1, 0, 1, \&Slim::Control::Commands::alarmCommand]);
	addDispatch(['alarm',          'playlists',      '_index',     '_quantity'],                       [0, 1, 1, \&Slim::Control::Queries::alarmPlaylistsQuery]);
	addDispatch(['alarms',         '_index',         '_quantity'],                                     [1, 1, 1, \&Slim::Control::Queries::alarmsQuery]);
	addDispatch(['album',          '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::cursonginfoQuery]);
	addDispatch(['albums',         '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::albumsQuery]);
	addDispatch(['artist',         '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::cursonginfoQuery]);
	addDispatch(['artists',        '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::artistsQuery]);
	addDispatch(['artworkspec',    'add',            '_spec',      '_name'],                           [0, 0, 0, \&Slim::Control::Commands::artworkspecCommand]);
	addDispatch(['button',         '_buttoncode',    '_time',      '_orFunction'],                     [1, 0, 0, \&Slim::Control::Commands::buttonCommand]);
	addDispatch(['client',         'forget'],                                                          [1, 0, 0, \&Slim::Control::Commands::clientForgetCommand]);
	addDispatch(['connect',        '_where'],                                                          [1, 0, 0, \&Slim::Control::Commands::clientConnectCommand]);
	addDispatch(['connected',      '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::connectedQuery]);
	addDispatch(['contextmenu',    '_index',         '_quantity'],                                     [1, 1, 1, \&Slim::Control::Queries::contextMenuQuery]);
	addDispatch(['current_title',  '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::cursonginfoQuery]);
	addDispatch(['debug',          '_debugflag',     '?'],                                             [0, 1, 0, \&Slim::Control::Queries::debugQuery]);
	addDispatch(['debug',          '_debugflag',     '_newvalue'],                                     [0, 0, 0, \&Slim::Control::Commands::debugCommand]);
	addDispatch(['disconnect',     '_playerid',      '_from'],                                         [0, 0, 0, \&Slim::Control::Commands::disconnectCommand]);
	addDispatch(['display',        '?',              '?'],                                             [1, 1, 0, \&Slim::Control::Queries::displayQuery]);
	addDispatch(['display',        '_line1',         '_line2',     '_duration'],                       [1, 0, 0, \&Slim::Control::Commands::displayCommand]);
	addDispatch(['displaynow',     '?',              '?'],                                             [1, 1, 0, \&Slim::Control::Queries::displaynowQuery]);
	addDispatch(['displaystatus'],                                                                     [1, 1, 1, \&Slim::Control::Queries::displaystatusQuery]);
	addDispatch(['duration',       '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::cursonginfoQuery]);
	addDispatch(['readdirectory',  '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::readDirectoryQuery]);
	addDispatch(['genre',          '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::cursonginfoQuery]);
	addDispatch(['genres',         '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::genresQuery]);
	addDispatch(['getstring',      '_tokens'],                                                         [0, 1, 0, \&Slim::Control::Queries::getStringQuery]);
	addDispatch(['info',           'total',          'albums',     '?'],                               [0, 1, 0, \&Slim::Control::Queries::infoTotalQuery]);
	addDispatch(['info',           'total',          'artists',    '?'],                               [0, 1, 0, \&Slim::Control::Queries::infoTotalQuery]);
	addDispatch(['info',           'total',          'genres',     '?'],                               [0, 1, 0, \&Slim::Control::Queries::infoTotalQuery]);
	addDispatch(['info',           'total',          'songs',      '?'],                               [0, 1, 0, \&Slim::Control::Queries::infoTotalQuery]);
	addDispatch(['info',           'total',          'duration',   '?'],                               [0, 1, 0, \&Slim::Control::Queries::infoTotalQuery]);
	addDispatch(['ir',             '_ircode',        '_time'],                                         [1, 0, 0, \&Slim::Control::Commands::irCommand]);
	addDispatch(['irenable',       '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::irenableQuery]);
	addDispatch(['irenable',       '_newvalue'],                                                       [1, 0, 0, \&Slim::Control::Commands::irenableCommand]);
	addDispatch(['libraries'],                                                                         [0, 1, 0, \&Slim::Control::Queries::librariesQuery]);
	addDispatch(['libraries',      'getid'],                                                           [1, 1, 0, \&Slim::Control::Queries::librariesQuery]);
	addDispatch(['linesperscreen', '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::linesperscreenQuery]);
	addDispatch(['logging'],                                                                           [0, 0, 1, \&Slim::Control::Commands::loggingCommand]);
	addDispatch(['mixer',          'bass',           '?'],                                             [1, 1, 0, \&Slim::Control::Queries::mixerQuery]);
	addDispatch(['mixer',          'bass',           '_newvalue'],                                     [1, 0, 1, \&Slim::Control::Commands::mixerCommand]);
	addDispatch(['mixer',          'muting',         '?'],                                             [1, 1, 0, \&Slim::Control::Queries::mixerQuery]);
	addDispatch(['mixer',          'muting',         '_newvalue'],                                     [1, 0, 1, \&Slim::Control::Commands::mixerCommand]);
	addDispatch(['mixer',          'stereoxl',       '?'],                                             [1, 1, 0, \&Slim::Control::Queries::mixerQuery]);
	addDispatch(['mixer',          'stereoxl',       '_newvalue'],                                     [1, 0, 1, \&Slim::Control::Commands::mixerCommand]);
	addDispatch(['mixer',          'pitch',          '?'],                                             [1, 1, 0, \&Slim::Control::Queries::mixerQuery]);
	addDispatch(['mixer',          'pitch',          '_newvalue'],                                     [1, 0, 1, \&Slim::Control::Commands::mixerCommand]);
	addDispatch(['mixer',          'treble',         '?'],                                             [1, 1, 0, \&Slim::Control::Queries::mixerQuery]);
	addDispatch(['mixer',          'treble',         '_newvalue'],                                     [1, 0, 1, \&Slim::Control::Commands::mixerCommand]);
	addDispatch(['mixer',          'volume',         '?'],                                             [1, 1, 0, \&Slim::Control::Queries::mixerQuery]);
	addDispatch(['mixer',          'volume',         '_newvalue'],                                     [1, 0, 1, \&Slim::Control::Commands::mixerCommand]);
	addDispatch(['mode',           '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::modeQuery]);
	# musicfolder is only here for backwards compatibility - it's calling mediafolder internally
	addDispatch(['musicfolder',    '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::musicfolderQuery]);
	addDispatch(['mediafolder',    '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::mediafolderQuery]);
	addDispatch(['name',           '_newvalue'],                                                       [1, 0, 0, \&Slim::Control::Commands::nameCommand]);
	addDispatch(['name',           '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::nameQuery]);
	addDispatch(['path',           '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::cursonginfoQuery]);
	addDispatch(['pause',          '_newvalue',      '_fadein', '_suppressShowBriefly'],               [1, 0, 0, \&Slim::Control::Commands::playcontrolCommand]);
	addDispatch(['play',           '_fadein'],                                                         [1, 0, 0, \&Slim::Control::Commands::playcontrolCommand]);
	addDispatch(['player',         'address',        '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'count',          '?'],                                             [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'displaytype',    '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'id',             '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'uuid',           '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'ip',             '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'model',          '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'isplayer',       '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'name',           '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['player',         'canpoweroff',    '_IDorIndex', '?'],                               [0, 1, 0, \&Slim::Control::Queries::playerXQuery]);
	addDispatch(['playerpref',     '_prefname',      '?'],                                             [1, 1, 0, \&Slim::Control::Queries::prefQuery]);
	addDispatch(['playerpref',     'validate',       '_prefname',  '_newvalue'],                       [1, 1, 0, \&Slim::Control::Queries::prefValidateQuery]);
	addDispatch(['playerpref',     '_prefname',      '_newvalue'],                                     [1, 0, 1, \&Slim::Control::Commands::prefCommand]);
	addDispatch(['players',        '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::playersQuery]);
	addDispatch(['playlist',       'add',            '_item',      '_title'],                          [1, 0, 0, \&Slim::Control::Commands::playlistXitemCommand]);
	addDispatch(['playlist',       'addalbum',       '_genre',     '_artist',     '_album', '_title'], [1, 0, 0, \&Slim::Control::Commands::playlistXalbumCommand]);
	addDispatch(['playlist',       'addtracks',      '_what',      '_listref'],                        [1, 0, 0, \&Slim::Control::Commands::playlistXtracksCommand]);
	addDispatch(['playlist',       'album',          '_index',     '?'],                               [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'append',         '_item',      '_title'],                          [1, 0, 0, \&Slim::Control::Commands::playlistXitemCommand]);
	addDispatch(['playlist',       'artist',         '_index',     '?'],                               [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'clear'],                                                           [1, 0, 0, \&Slim::Control::Commands::playlistClearCommand]);
	addDispatch(['playlist',       'delete',         '_index'],                                        [1, 0, 0, \&Slim::Control::Commands::playlistDeleteCommand]);
	addDispatch(['playlist',       'deletealbum',    '_genre',     '_artist',     '_album', '_title'], [1, 0, 0, \&Slim::Control::Commands::playlistXalbumCommand]);
	addDispatch(['playlist',       'deleteitem',     '_item'],                                         [1, 0, 0, \&Slim::Control::Commands::playlistDeleteitemCommand]);
	addDispatch(['playlist',       'deletetracks',   '_what',      '_listref'],                        [1, 0, 0, \&Slim::Control::Commands::playlistXtracksCommand]);
	addDispatch(['playlist',       'duration',       '_index',     '?'],                               [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'genre',          '_index',     '?'],                               [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'index',          '?'],                                             [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'index',          '_index',     '_fadein', '_noplay', '_seekdata'], [1, 0, 0, \&Slim::Control::Commands::playlistJumpCommand]);
	addDispatch(['playlist',       'insert',         '_item',      '_title'],                          [1, 0, 0, \&Slim::Control::Commands::playlistXitemCommand]);
	addDispatch(['playlist',       'insertlist',     '_item'],                                         [1, 0, 0, \&Slim::Control::Commands::playlistXitemCommand]);
	addDispatch(['playlist',       'insertalbum',    '_genre',     '_artist',     '_album', '_title'], [1, 0, 0, \&Slim::Control::Commands::playlistXalbumCommand]);
	addDispatch(['playlist',       'inserttracks',   '_what',      '_listref'],                        [1, 0, 0, \&Slim::Control::Commands::playlistXtracksCommand]);
	addDispatch(['playlist',       'jump',           '?'],                                             [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'jump',           '_index',     '_fadein', '_noplay', '_seekdata'], [1, 0, 0, \&Slim::Control::Commands::playlistJumpCommand]);
	addDispatch(['playlist',       'load',           '_item'],                                         [1, 0, 1, \&Slim::Control::Commands::playlistXitemCommand]);
	addDispatch(['playlist',       'loadalbum',      '_genre',     '_artist',     '_album', '_title'], [1, 0, 0, \&Slim::Control::Commands::playlistXalbumCommand]);
	addDispatch(['playlist',       'loadtracks',     '_what',      '_listref',    '_fadein', '_index'],[1, 0, 0, \&Slim::Control::Commands::playlistXtracksCommand]);
	addDispatch(['playlist',       'modified',       '?'],                                             [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'move',           '_fromindex', '_toindex'],                        [1, 0, 0, \&Slim::Control::Commands::playlistMoveCommand]);
	addDispatch(['playlist',       'name',           '?'],                                             [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'path',           '_index',     '?'],                               [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'play',           '_item',      '_title',      '_fadein'],          [1, 0, 0, \&Slim::Control::Commands::playlistXitemCommand]);
	addDispatch(['playlist',       'playalbum',      '_genre',     '_artist',     '_album', '_title'], [1, 0, 0, \&Slim::Control::Commands::playlistXalbumCommand]);
	addDispatch(['playlist',       'playlistsinfo'],                                                   [1, 1, 1, \&Slim::Control::Queries::playlistPlaylistsinfoQuery]);
	addDispatch(['playlist',       'playtracks',     '_what',      '_listref',    '_fadein', '_index'],[1, 0, 0, \&Slim::Control::Commands::playlistXtracksCommand]);
	addDispatch(['playlist',       'preview'],                                                         [1, 0, 1, \&Slim::Control::Commands::playlistPreviewCommand]);
	addDispatch(['playlist',       'remote',         '_index',     '?'],                               [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'repeat',         '?'],                                             [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'repeat',         '_newvalue'],                                     [1, 0, 0, \&Slim::Control::Commands::playlistRepeatCommand]);
	addDispatch(['playlist',       'resume',         '_item'],                                         [1, 0, 1, \&Slim::Control::Commands::playlistXitemCommand]);
	addDispatch(['playlist',       'save',           '_title'],                                        [1, 0, 1, \&Slim::Control::Commands::playlistSaveCommand]);
	addDispatch(['playlist',       'shuffle',        '?'],                                             [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'shuffle',        '_newvalue'],                                     [1, 0, 0, \&Slim::Control::Commands::playlistShuffleCommand]);
	addDispatch(['playlist',       'title',          '_index',     '?'],                               [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'tracks',         '?'],                                             [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'url',            '?'],                                             [1, 1, 0, \&Slim::Control::Queries::playlistXQuery]);
	addDispatch(['playlist',       'zap',            '_index'],                                        [1, 0, 0, \&Slim::Control::Commands::playlistZapCommand]);
	addDispatch(['playlistcontrol'],                                                                   [1, 0, 1, \&Slim::Control::Commands::playlistcontrolCommand]);
	addDispatch(['playlists',      '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::playlistsQuery]);
	addDispatch(['playlists',      'edit'],                                                            [0, 0, 1, \&Slim::Control::Commands::playlistsEditCommand]);
	addDispatch(['playlists',      'delete'],                                                          [0, 0, 1, \&Slim::Control::Commands::playlistsDeleteCommand]);
	addDispatch(['playlists',      'new'],                                                             [0, 0, 1, \&Slim::Control::Commands::playlistsNewCommand]);
	addDispatch(['playlists',      'rename'],                                                          [0, 0, 1, \&Slim::Control::Commands::playlistsRenameCommand]);
	addDispatch(['playlists',      'tracks',         '_index',     '_quantity'],                       [0, 1, 1, \&Slim::Control::Queries::playlistsTracksQuery]);
	addDispatch(['power',          '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::powerQuery]);
	addDispatch(['power',          '_newvalue',      '_noplay'],                                       [1, 0, 1, \&Slim::Control::Commands::powerCommand]);
	addDispatch(['pragma',         '_pragma'],                                                         [0, 0, 0, \&Slim::Control::Commands::pragmaCommand]);
	addDispatch(['pref',           '_prefname',      '?'],                                             [0, 1, 0, \&Slim::Control::Queries::prefQuery]);
	addDispatch(['pref',           'validate',       '_prefname',  '_newvalue'],                       [0, 1, 0, \&Slim::Control::Queries::prefValidateQuery]);
	addDispatch(['pref',           '_prefname',      '_newvalue'],                                     [0, 0, 1, \&Slim::Control::Commands::prefCommand]);
	addDispatch(['remote',         '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::cursonginfoQuery]);
	addDispatch(['rescan',         '?'],                                                               [0, 1, 0, \&Slim::Control::Queries::rescanQuery]);
	addDispatch(['rescan',         '_mode',          '_singledir'],                                    [0, 0, 0, \&Slim::Control::Commands::rescanCommand]);
	addDispatch(['rescanprogress'],                                                                    [0, 1, 1, \&Slim::Control::Queries::rescanprogressQuery]);
	addDispatch(['restartserver'],                                                                     [0, 0, 0, \&Slim::Control::Commands::stopServer]);
	addDispatch(['search',         '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::searchQuery]);
	addDispatch(['serverstatus',   '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::serverstatusQuery]);
	addDispatch(['show'],                                                                              [1, 0, 1, \&Slim::Control::Commands::showCommand]);
	addDispatch(['signalstrength', '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::signalstrengthQuery]);
	addDispatch(['sleep',          '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::sleepQuery]);
	addDispatch(['sleep',          '_newvalue'],                                                       [1, 0, 0, \&Slim::Control::Commands::sleepCommand]);
	addDispatch(['songinfo',       '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::songinfoQuery]);
	addDispatch(['songs',          '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::titlesQuery]);
	addDispatch(['status',         '_index',         '_quantity'],                                     [1, 1, 1, \&Slim::Control::Queries::statusQuery]);
	addDispatch(['stop'],                                                                              [1, 0, 0, \&Slim::Control::Commands::playcontrolCommand]);
	addDispatch(['stopserver'],                                                                        [0, 0, 0, \&Slim::Control::Commands::stopServer]);
	addDispatch(['sync',           '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::syncQuery]);
	addDispatch(['sync',           '_indexid-'],                                                       [1, 0, 1, \&Slim::Control::Commands::syncCommand]);
	addDispatch(['syncgroups',     '?'],                                                               [0, 1, 0, \&Slim::Control::Queries::syncGroupsQuery]);
	addDispatch(['time',           '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::timeQuery]);
	addDispatch(['time',           '_newvalue'],                                                       [1, 0, 0, \&Slim::Control::Commands::timeCommand]);
	addDispatch(['title',          '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::cursonginfoQuery]);
	addDispatch(['titles',         '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::titlesQuery]);
	addDispatch(['tracks',         '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::titlesQuery]);
	addDispatch(['version',        '?'],                                                               [0, 1, 0, \&Slim::Control::Queries::versionQuery]);
	addDispatch(['wipecache',      '_queue'],                                                          [0, 0, 0, \&Slim::Control::Commands::wipecacheCommand]);
	addDispatch(['years',          '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::yearsQuery]);
	addDispatch(['works',          '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::worksQuery]);
	addDispatch(['artwork',        '_artworkid'],                                                      [0, 0, 0, \&Slim::Control::Queries::showArtwork]);
	addDispatch(['rating',         '_item',          '?'],                                             [0, 1, 0, \&Slim::Control::Commands::ratingCommand]);
	addDispatch(['rating',         '_item',          '_rating'],                                       [0, 0, 0, \&Slim::Control::Commands::ratingCommand]);

# NOTIFICATIONS
	addDispatch(['client',         'disconnect'],                                                      [1, 0, 0, undef]);
	addDispatch(['client',         'new'],                                                             [1, 0, 0, undef]);
	addDispatch(['client',         'reconnect'],                                                       [1, 0, 0, undef]);
	addDispatch(['client',         'upgrade_firmware'],                                                [1, 0, 0, undef]);
	addDispatch(['playlist',       'load_done'],                                                       [1, 0, 0, undef]);
	addDispatch(['playlist',       'newsong'],                                                         [1, 0, 0, undef]);
	addDispatch(['playlist',       'open',           '_path'],                                         [1, 0, 0, undef]);
	addDispatch(['playlist',       'sync'],                                                            [1, 0, 0, undef]);
	addDispatch(['playlist',       'cant_open',      '_url',         '_error'],                        [1, 0, 0, undef]);
	addDispatch(['playlist',       'pause',          '_newvalue'],                                     [1, 0, 0, undef]);
	addDispatch(['playlist',       'stop'],                                                            [1, 0, 0, undef]);
	addDispatch(['rescan',         'done'],                                                            [0, 0, 0, undef]);
	addDispatch(['library',        'changed',        '_newvalue'],                                     [0, 0, 0, undef]);
	addDispatch(['unknownir',      '_ircode',        '_time'],                                         [1, 0, 0, undef]);
	addDispatch(['prefset',        '_namespace',     '_prefname',  '_newvalue'],                       [0, 0, 1, undef]);
	addDispatch(['displaynotify',  '_type',          '_parts', '_duration'],                           [1, 0, 0, undef]);
	addDispatch(['alarm',          'sound',          '_id'],                                           [1, 0, 0, undef]);
	addDispatch(['alarm',          'end',            '_id'],                                           [1, 0, 0, undef]);
	addDispatch(['alarm',          'snooze',         '_id'],                                           [1, 0, 0, undef]);
	addDispatch(['alarm',          'snooze_end',     '_id'],                                           [1, 0, 0, undef]);
	addDispatch(['fwdownloaded',   '_machine'],                                                        [0, 0, 0, undef]);
	addDispatch(['newmetadata'],                                                                       [1, 0, 0, undef]);

# DEPRECATED
	addDispatch(['mode',           'pause'],                                                           [1, 0, 0, \&Slim::Control::Commands::playcontrolCommand]);
	addDispatch(['mode',           'play'],                                                            [1, 0, 0, \&Slim::Control::Commands::playcontrolCommand]);
	addDispatch(['mode',           'stop'],                                                            [1, 0, 0, \&Slim::Control::Commands::playcontrolCommand]);
	# use commands "pause", "play" and "stop"

	addDispatch(['gototime',       '?'],                                                               [1, 1, 0, \&Slim::Control::Queries::timeQuery]);
	addDispatch(['gototime',       '_newvalue'],                                                       [1, 0, 0, \&Slim::Control::Commands::timeCommand]);
	# use command "time"

	addDispatch(['playlisttracks', '_index',         '_quantity'],                                     [0, 1, 1, \&Slim::Control::Queries::playlistsTracksQuery]);
	# use query "playlists tracks"

######################################################################################################################################################################

	return if !main::WEBUI;

	# Normal Lyrion Music Server commands can be accessed with URLs like
	#   http://localhost:9000/status.html?p0=pause&player=00%3A00%3A00%3A00%3A00%3A00
	# Use the protectCommand() API to prevent CSRF attacks on commands -- including commands
	# not intended for use via the web interface!
	#
	# protect some commands regardless of args passed to them
	require Slim::Web::HTTP::CSRF;
	Slim::Web::HTTP::CSRF->protectCommand([qw|alarm alarms button client debug display displaynow ir pause play playlist
					playlistcontrol playlists stop stopserver restartserver wipecache prefset mode
					power rescan sleep sync time gototime
					mixer playerpref pref|]);
	# protect changing setting for command + 1-arg ("?" query always allowed -- except "?" is "%3F" once escaped)
	#Slim::Web::HTTP::CSRF->protectCommand(['power', 'rescan', 'sleep', 'sync', 'time', 'gototime'],'[^\?].*');
	# protect changing setting for command + 2 args, 2nd as new value ("?" query always allowed)
	#Slim::Web::HTTP::CSRF->protectCommand(['mixer', 'playerpref', 'pref'],'.*','[^\?].*');	# protect changing volume ("?" query always allowed)

}

# add an entry to the dispatch DB
sub addDispatch {
	my $arrayCmdRef  = shift; # the array containing the command or query
	my $arrayDataRef = shift; # the array containing the function to call

	# the new dispatch table is of the following format:
	#
	# $dispatchDB->{
	#    verb1 => {
	#       verb2 => {
	#          verb3a => {
	#             :: => [
	#                [ '_params1', '_params2', '_params3' ], 0, 0, 0, \&func3a_cmd   ],
	#                [ '_params1', '_params2', '?'        ], 0, 0, 0, \&func3a_query ],
	#             ],
	#          },
	#          verb3b => {
	#             :: => [
	#                [ '_params1', '_params2', '_params3' ], 0, 0, 0, \&func3b_cmd   ],
	#                [ '_params1', '_params2', '?'        ], 0, 0, 0, \&func3b_query ],
	#             ],
	#          },
	#
	# the request verbs form the hash keys, with each valid request indicated by a leaf with the special key '::'
	# within each leaf is an array with two entries - 0 for the cmd and 1 for the query matching this request
	# (a query is selected if the last entry in $arrayCmdRef is '?')
	# within each of these arrays are an array of parameters for this request followed by the $arrayDataRef

	my @request;
	my @params;
	my $query = 0;

	# split CmdRef into request verbs and param tokens
	for my $entry (@$arrayCmdRef) {

		if (!@params) {

			if ($entry =~ /^_|^\?$/) {
				push @params, $entry;
			} else {
				push @request, $entry;
			}

		} else {

			if ($entry !~ /^_|^\?$/) {
				$log->warn("param $entry invalid - must start with _ or be ?");
				return;
			}

			push @params, $entry;
		}
	}

	# validate the function array
	if (ref $arrayDataRef ne 'ARRAY' || @$arrayDataRef != 4 || (defined $arrayDataRef->[3] && ref $arrayDataRef->[3] ne 'CODE')) {
		$log->warn("invalid data ref");
		return;
	}

	# is this a query
	if ($arrayCmdRef->[-1] eq '?') {
		if ($arrayDataRef->[1]) {
			$query = 1;
		} else {
			$log->warn("bady formed query - last param is ? but query flag not set");
		}
	}

	# find the leaf in the dispatch table or create a new one
	my $entry = $dispatchDB;

	for my $request (@request) {
		$entry = $entry->{$request} ||= {};
	}

	$entry = $entry->{'::'} ||= [];

	# store the old function so a new entry can replace an old one and call it
	# FIXME - should we check the params for the replacement are the same?
	my $prevFunc = defined $entry->[$query] ? $entry->[$query]->[4] : undef;

	main::INFOLOG && $log->is_info && $log->info("Adding dispatch: [", join(' ', @$arrayCmdRef) . "]");

	$entry->[$query] = [ \@params, @$arrayDataRef ];

	return $prevFunc;
}

# add a subscriber to be notified of requests
sub subscribe {
	my $subscriberFuncRef = shift || return;
	my $requestsRef = shift;
	my $client = shift;

	if ( blessed($client) ) {
		$listeners{ $client->id . $subscriberFuncRef } = [ __requestRE($requestsRef), $subscriberFuncRef, $requestsRef, $client->id ];
	}
	else {
		$listeners{$subscriberFuncRef} = [ __requestRE($requestsRef), $subscriberFuncRef, $requestsRef ];
	}

	# rebuild the super regexp for the current list of listeners
	__updateListenerSuperRE();

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug(sprintf(
			"Request from: %s - (%d listeners)\n",
			Slim::Utils::PerlRunTime::realNameForCodeRef($subscriberFuncRef),
			scalar(keys %listeners)
		));
	}
}

# remove a subscriber
sub unsubscribe {
	my $subscriberFuncRef = shift;
	my $client = shift;

	if ( blessed($client) ) {
		delete $listeners{ $client->id . $subscriberFuncRef };
	}
	else {
		delete $listeners{$subscriberFuncRef};
	}

	# rebuild the super regexp for the current list of listeners
	__updateListenerSuperRE();

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug(sprintf(
			"Request from: %s - (%d listeners)\n",
			Slim::Utils::PerlRunTime::realNameForCodeRef($subscriberFuncRef),
			scalar(keys %listeners)
		));
	}
}

# notify listeners from an array, useful for notifying w/o execution
# (requests must, however, be defined in the dispatch table)
sub notifyFromArray {
	my $client         = shift;     # client, if any, to which the query applies
	my $requestLineRef = shift;     # reference to an array containing the query verbs

	if ( main::INFOLOG && $log->is_info ) {
		$log->info(sprintf("(%s)", join(" ", @{$requestLineRef})));
	}

	my $request = Slim::Control::Request->new(
		(blessed($client) ? $client->id() : undef),
		$requestLineRef,
		1, # force use of tied ixhash to maintain ordering of the array
	);

	push @notificationQueue, $request;
}

# sends notifications for first entry in queue - called once per idle loop
sub checkNotifications {
	my $request = shift @notificationQueue || return 0;

	$request->notify();

	return 1;
}

# convenient function to execute a request from an array, with optional
# callback parameters. Returns the Request object.
sub executeRequest {
	my($client, $parrayref, $callbackf, $callbackargs) = @_;

	# create a request from the array
	my $request = Slim::Control::Request->new(
		(blessed($client) ? $client->id() : undef),
		$parrayref
	);

	if (defined $request && $request->isStatusDispatchable()) {

		# add callback params
		$request->callbackParameters($callbackf, $callbackargs);

		$request->execute();
	}

	return $request;
}

=head2 unregisterAutoExecute ( $connectionID )

Removes all subscriptions for this $connectionID. Returns 1 if there were any, else 0.

=cut
sub unregisterAutoExecute{
	my $connectionID = shift;

	if ($subscribers{$connectionID}) {

		# kill any timers
		for my $name (keys %{$subscribers{$connectionID}}) {
			for my $clientid (keys %{$subscribers{$connectionID}{$name}}) {

				my $request = delete $subscribers{$connectionID}{$name}{$clientid};

				if (my $cleanup = $request->autoExecuteCleanup()) {
					eval { &{$cleanup}($request, $connectionID) };
				}

				Slim::Utils::Timers::killTimers($request, \&__autoexecute);
			}
		}

		# delete everything linked to connection
		delete $subscribers{$connectionID};

		return 1;
	}
	return 0;
}

=head2 hasSubscribers ( $name, $clientid )

Returns true if there are subscribers for $name/$clientid on any connection

=cut
sub hasSubscribers {
	my $name     = shift;
	my $clientid = shift;

	for my $connectionID (keys %subscribers) {
		return 1 if $subscribers{$connectionID}{$name} && $subscribers{$connectionID}{$name}{$clientid};
	}

	return 0;
}

=head2 alwaysOrder ( $val )

Set the flag to always order elements stored in request objects.  This forces the use of tied IxHashes
for all requests rather than just those requests which ask for it in Slim::Controll::Request->new()

It is required if renderAsArray is to be called on the request and so is set by the cli handler whenever
there are cli subscriptions active.

=cut
sub alwaysOrder {
	$alwaysUseIxHashes = shift;
}

################################################################################
# Constructors
################################################################################

=head2 new ( clientid, requestLineRef, paramsRef, useIxHashes )

Creates a new Request object. All parameters are optional. clientid is the
client ID the request applies to. requestLineRef is a reference to an array
containing the request terms (f.e. ['pause']). paramsRef is a reference to
a hash containing the request parameters (tags in CLI lingo, f.e. {sort=>albums}).

requestLinRef is parsed to match an entry in the dispatch table, and parameters
found there are added to the params. It best to use requestLineRef for all items
defined in the dispatch table and paramsRef only for tags.

useIxHashes indicates that the response is expected to serialised on the cli and
so order of params and results should be maintained using IxHashes.

=cut

sub new {
	my $class          = shift;      # class to construct
	my $clientid       = shift;      # clientid, if any, to which the request applies
	my $requestLineRef = shift;      # reference to an array containing the
                                     # request verbs
	my $useIxHashes    = shift;      # request requires param ordering to be maintained (cli)

	$useIxHashes ||= $alwaysUseIxHashes; # if a cli subscription exists then always use IxHashes

	my @request;
	my %result;
	my %params;

	if ($useIxHashes) {
		tie %params, "Tie::IxHash";
		tie %result, "Tie::IxHash";
	}

	# initialise only those keys which do no init to undef
	my $self = {
	   _request   => \@request,
	   _params    => \%params,
	   _results   => \%result,
	   _clientid  => $clientid,
	   _useixhash => $useIxHashes,
	   _cb_enable => 1,
	   _langoverride => undef,
	};

	bless $self, $class;

	# return clean object if there is no request line
	if (!$requestLineRef) {
		$self->{'_status'} = 104;
		return $self;
	}

	# parse the line
	my $i = 0;
	my $found;
	my $search = $dispatchDB;

	# traverse the dispatch tree looking for a match on the request verbs
	while ($search->{ $requestLineRef->[$i] }) {
		push @request, $requestLineRef->[$i];
		$search = $search->{ $requestLineRef->[$i++] };
		last unless defined $requestLineRef->[$i];
	}

	if ($search->{'::'}) { # '::' is the special key indicating a leaf, i.e. verbs match

		# choose the parameter array based on whether last param is '?'
		# 1 = array for queries ending in ?, 0 otherwise

		if (!defined $requestLineRef->[-1] || $requestLineRef->[-1] ne '?') {

			$found = $search->{'::'}->[0];

			# extract the params
			for my $param (@{$found->[0]}) {
				$params{$param} = $requestLineRef->[$i++];
			}

		} else {

			$found = $search->{'::'}->[1];

			# extract the params excluding '?'
			for my $param (@{$found->[0]}) {
				$params{$param} = $requestLineRef->[$i] if $param ne '?';
				$i++;
			}
		}

		# found is now an array:
		# 0 = array of params
		# 1 = needsClient
		# 2 = isQuery
		# 3 = hasTags
		# 4 = function

		# extract any remaining params
		for (;$i < scalar @$requestLineRef; $i++) {

			if ($found->[3] && $requestLineRef->[$i] && $requestLineRef->[$i] =~ /([^:]+):(.*)/) {

				# tagged params
				$params{$1} = $2;

			} else {

				# positional params
				$params{"_p$i"} = $requestLineRef->[$i];
			}
		}

		$self->{'_requeststr'} = join(',', @request);

		$self->{'_needClient'} = $found->[1];
		$self->{'_isQuery'}    = $found->[2];
		$self->{'_func'}       = $found->[4];

		# perform verificaton based on found
		if (!$found->[4]) {
			# Mark as not dispatachable as no function or we ran out of params
			$self->{'_status'} = 104;

		} elsif ($found->[1] && (!$clientid || !$Slim::Player::Client::clientHash{$clientid})) {

			$self->{'_clientid'} = undef;

			if ($found->[1] == 2 && $clientid) {
				# Special case where there is a clientid but there is no attached client
				$self->{'_disconnected_clientid'} = $clientid;
				$self->{'_status'} = 1;
			} else {
				# Mark as not dispatchable as no client
				$self->{'_status'} = 103;
			}

		} else {
			# Mark as dispatchable
			$self->{'_status'} = 1;
		}


	} else {

		# No match in dispatch table - mark as not dispatchable & copy remaining to positional params for cli echoing
		$self->{'_status'} = 104;

		for (;$i < scalar @$requestLineRef; $i++) {
			$params{"_p$i"} = $requestLineRef->[$i];
		}

		if (main::INFOLOG && $log->is_info) {
			$log->info("Request [" . join(' ', @{$requestLineRef}) . "]: no match in dispatchDB!");
		}
	}

	return $self;
}

# makes a request out of another one, discarding results and callback data.
# except for '_private' which we don't know about, all data is
# duplicated
sub virginCopy {
	my $self = shift;

	my $copy = Slim::Control::Request->new($self->clientid());

	# fill in the scalars
	$copy->{'_isQuery'} = $self->{'_isQuery'};
	$copy->{'_needClient'} = $self->{'_needClient'};
	$copy->{'_func'} = \&{$self->{'_func'}};
	$copy->{'_source'} = $self->{'_source'};
	$copy->{'_private'} = $self->{'_private'};
	$copy->{'_connectionid'} = $self->{'_connectionid'};
	$copy->{'_ae_callback'} = $self->{'_ae_callback'};
	$copy->{'_ae_filter'} = $self->{'_ae_filter'};
	$copy->{'_ae_cleanup'} = $self->{'_ae_cleanup'};
	$copy->{'_requeststr'} = $self->{'_requeststr'};
	$copy->{'_useixhash'} = $self->{'_useixhash'};

	# duplicate the arrays and hashes
	my @request = @{$self->{'_request'}};
	$copy->{'_request'} = \@request;

	$copy->{'_params'} = $self->getParamsCopy();

	$self->validate();

	return $copy;
}


################################################################################
# Read/Write basic query attributes
################################################################################

# sets/returns the client (we store the id only)
sub client {
	my $self = shift;
	my $client = shift;

	if (defined $client) {
		$self->{'_clientid'} = (blessed($client) ? $client->id() : undef);
		$self->validate();
	}

	return Slim::Player::Client::getClient($self->{'_clientid'});
}

sub disconnectedClientID {
	my $self = shift;

	return $self->{_disconnected_clientid};
}

# sets/returns the client ID
sub clientid {
	if (defined $_[1]) {
		$_[0]->{'_clientid'} = $_[1];
		$_[0]->validate();
	}

	return $_[0]->{'_clientid'};
}

# sets/returns the need client state
sub needClient {
	my $self = shift;
	my $needClient = shift;

	if (defined $needClient) {
		$self->{'_needClient'} = $needClient;
		$self->validate();
	}

	return $self->{'_needClient'};
}

# sets/returns the query state
sub query {
	my $self = shift;
	my $isQuery = shift;

	$self->{'_isQuery'} = $isQuery if defined $isQuery;

	return $self->{'_isQuery'};
}

# sets/returns the function that executes the request
sub function {
	my $self = shift;
	my $newvalue = shift;

	if (defined $newvalue) {
		$self->{'_func'} = $newvalue;
		$self->validate();
	}

	return $self->{'_func'};
}

# sets/returns the callback enabled state
sub callbackEnabled {
	my $self = shift;
	my $newvalue = shift;

	$self->{'_cb_enable'} = $newvalue if defined $newvalue;

	return $self->{'_cb_enable'};
}

# sets/returns the callback function
sub callbackFunction {
	my $self = shift;
	my $newvalue = shift;

	$self->{'_cb_func'} = $newvalue if defined $newvalue;

	return $self->{'_cb_func'};
}

# sets/returns the callback arguments
sub callbackArguments {
	my $self = shift;
	my $newvalue = shift;

	$self->{'_cb_args'} = $newvalue if defined $newvalue;

	return $self->{'_cb_args'};
}

# sets/returns the request source
sub source {
	my $self = shift;
	my $newvalue = shift;

	$self->{'_source'} = $newvalue if defined $newvalue;

	return $self->{'_source'};
}

# sets/returns the source connectionid
sub connectionID {
	my $self = shift;
	my $newvalue = shift;

	$self->{'_connectionid'} = $newvalue if defined $newvalue;

	return $self->{'_connectionid'};
}

# sets/returns the source subscribe callback
sub autoExecuteCallback {
	my $self = shift;
	my $newvalue = shift;

	$self->{'_ae_callback'} = $newvalue if defined $newvalue;

	return $self->{'_ae_callback'};
}

# sets/returns the cleanup function for when autoexecute is cleared
sub autoExecuteCleanup {
	my $self = shift;
	my $newvalue = shift;

	$self->{'_ae_cleanup'} = $newvalue if defined $newvalue;

	return $self->{'_ae_cleanup'};
}

# remove the autoExecuteCallback for this request
sub removeAutoExecuteCallback {
	my $self = shift;

	$self->{'_ae_callback'} = undef;

	my $cnxid       = $self->connectionID();
	my $name        = $self->getRequestString();
	my $clientid    = $self->clientid() || 'global';
	my $cleanup     = $self->autoExecuteCleanup();
	my $request2del = $subscribers{$cnxid}{$name}{$clientid};

	main::DEBUGLOG && $log->debug("removeAutoExecuteCallback: deleting $cnxid - $name - $clientid");

	delete $subscribers{$cnxid}{$name}{$clientid};

	if ($cleanup) {
		eval { &{$cleanup}($self, $cnxid) };
	}

	# there should not be any of those, but just to be sure
	Slim::Utils::Timers::killTimers( $self, \&__autoexecute );
	Slim::Utils::Timers::killTimers( $request2del, \&__autoexecute );

	return 1;
}

# sets/returns the source subscribe callback
sub autoExecuteFilter {
	if ( defined $_[1] && ref $_[1] eq 'CODE' ) {
		$_[0]->{'_ae_filter'} = $_[1];
	}

	return $_[0]->{'_ae_filter'};
}


# sets/returns the source private data
sub privateData {
	my $self = shift;
	my $newvalue = shift;

	$self->{'_private'} = $newvalue if defined $newvalue;

	return $self->{'_private'};
}


################################################################################
# Read/Write status
################################################################################
# useful hash for debugging and as a reminder when writing new status methods
my %statusMap = (
	  0 => 'New',
	  1 => 'Dispatchable',
	  2 => 'Dispatched',
	  3 => 'Processing',
	 10 => 'Done',
#	 11 => 'Callback done',
	101 => 'Bad dispatch!',
	102 => 'Bad params!',
	103 => 'Missing client!',
	104 => 'Unknown in dispatch table',
	105 => 'Bad Lyrion Music Server config',
);

# validate the Request, make sure we are dispatchable
sub validate {
	my $self = shift;

	if (ref($self->{'_func'}) ne 'CODE') {

		$self->{'_status'}   = 104;

	}
	elsif ( $self->{_needClient} == 2 ) {
		# Allowed as a disconnected client
		$self->{_status} = 1;
	}
 	elsif ($self->{'_needClient'} && !$Slim::Player::Client::clientHash{$self->{'_clientid'}}){

		$self->{'_status'}   = 103;
		$self->{'_clientid'} = undef;

	} else {

		$self->{'_status'}   = 1;
	}
}

sub isStatusNew {
	return ($_[0]->{'_status'} == 0);
}

sub setStatusDispatchable {
	$_[0]->{'_status'} = 1;
}

sub isStatusDispatchable {
	return ($_[0]->{'_status'} == 1);
}

sub setStatusDispatched {
	$_[0]->{'_status'} = 2;
}

sub isStatusDispatched {
	return ($_[0]->{'_status'} == 2);
}

sub wasStatusDispatched {
	return ($_[0]->{'_status'} > 1);
}

sub setStatusProcessing {
	$_[0]->{'_status'} = 3;
}

sub isStatusProcessing {
	return ($_[0]->{'_status'} == 3);
}

sub setStatusDone {
	# if we are in processing state, we need to call executeDone AFTER setting
	# the status to Done...
	my $callDone = ($_[0]->{'_status'} == 3);
	$_[0]->{'_status'} = 10;
	$_[0]->executeDone() if $callDone;
}

sub isStatusDone {
	return ($_[0]->{'_status'} == 10);
}

sub isStatusError {
	return ($_[0]->{'_status'} > 100);
}

sub setStatusBadDispatch {
	$_[0]->{'_status'} = 101;
}

sub isStatusBadDispatch {
	return ($_[0]->{'_status'} == 101);
}

sub setStatusBadParams {
	$_[0]->{'_status'} = 102;
}

sub isStatusBadParams {
	return ($_[0]->{'_status'} == 102);
}

sub setStatusNeedsClient {
	$_[0]->{'_status'} = 103;
}

sub isStatusNeedsClient {
	return ($_[0]->{'_status'} == 103);
}

sub setStatusNotDispatchable {
	$_[0]->{'_status'} = 104;
}

sub isStatusNotDispatchable {
	return ($_[0]->{'_status'} == 104);
}

sub setStatusBadConfig {
	$_[0]->{'_status'} = 105;
}

sub isStatusBadConfig {
	return ($_[0]->{'_status'} == 105);
}

sub getStatusText {
	return ($statusMap{$_[0]->{'_status'}});
}

sub setLanguageOverride {
	my ($self, $lang) = @_;

	return if $lang eq Slim::Utils::Strings::getLanguage();

	$self->{'_langoverride'} = $lang;
}

sub getLanguageOverride {
	return $_[0]->{'_langoverride'};
}


################################################################################
# Request mgmt
################################################################################

# returns the request name. Read-only
sub getRequestString {
	my $self = shift;

	return join " ", @{$self->{_request}};
}

# add a request value to the request array
sub addRequest {
	my $self = shift;
	my $text = shift;

	push @{$self->{'_request'}}, $text;
}

sub getRequest {
	my $self = shift;
	my $idx = shift;

	return $self->{'_request'}->[$idx];
}

sub getRequestCount {
	my $self = shift;
	my $idx = shift;

	return scalar @{$self->{'_request'}};
}

################################################################################
# Param mgmt
################################################################################

# add a parameter
sub addParam {
	my $self = shift;
	my $key = shift;
	my $val = shift;

	${$self->{'_params'}}{$key} = $val;
}

# add a nameless parameter
sub addParamPos {
	my $self = shift;
	my $val = shift;

	${$self->{'_params'}}{ "_p" . keys %{$self->{'_params'}} } = $val;
}

# get a parameter by name
sub getParam {
	return $_[0]->{'_params'}->{ $_[1] };
}

# delete a parameter by name
sub deleteParam {
	my $self = shift;
	my $key = shift || return;

	delete ${$self->{'_params'}}{$key};
}

# returns a copy of all parameters
sub getParamsCopy {
	my $self = shift;

	my %paramHash;

	tie %paramHash, 'Tie::IxHash' if $self->{'_useixhash'};

	while (my ($key, $val) = each %{$self->{'_params'}}) {
		$paramHash{$key} = $val;
 	}
	return \%paramHash;
}

################################################################################
# Result mgmt
################################################################################

sub addResult {
	my $self = shift;
	my $key = shift;
	my $val = shift;

	${$self->{'_results'}}{$key} = $val;
}

sub setResultFirst {
	my $self = shift;
	my $key = shift;
	my $val = shift;

	if ($self->{'_useixhash'}) {
		(tied %{$self->{'_results'}})->Unshift($key => $val);
	} else {
		${$self->{'_results'}}{$key} = $val;
	}
}

sub addResultLoop {
	my $self = shift;
	my $loop = shift;
	my $loopidx = shift;
	my $key = shift;
	my $val = shift;

	my $array = $self->{_results}->{$loop} ||= [];

	if ( !defined $array->[$loopidx] ) {
		my %paramHash;
		tie %paramHash, 'Tie::IxHash' if $self->{_useixhash};

		$array->[$loopidx] = \%paramHash;
	}

	$array->[$loopidx]->{$key} = $val;
}

# same as addResultLoop but checks first the value is defined.
# optimized for speed
sub addResultLoopIfValueDefined {
	if ( defined $_[4] ) {
		goto &addResultLoop;
	}
}

sub setResultLoopHash {
	my $self = shift;
	my $loop = shift;
	my $loopidx = shift;
	my $hashRef = shift;

	if (!defined ${$self->{'_results'}}{$loop}) {
		${$self->{'_results'}}{$loop} = [];
	}

	${$self->{'_results'}}{$loop}->[$loopidx] = $hashRef;
}

sub sliceResultLoop {
	my $self     = shift;
	my $loop     = shift;
	my $start    = shift;
	my $quantity = shift || 0;

	if (defined ${$self->{'_results'}}{$loop}) {

		if ($start) {
			splice ( @{${$self->{'_results'}}{$loop}} , 0, $start);
		}
		if ($quantity && $quantity < scalar @{${$self->{'_results'}}{$loop}}) {
			splice ( @{${$self->{'_results'}}{$loop}} , $quantity);
		}
	}
}

sub string {
	my $self = shift;
	my $name = uc(shift);

	if ( my $client = $self->client() ) {
		return cstring($client, $name, @_);
	}

	if ( my $lang = $self->getLanguageOverride() ) {
		my $strings = Slim::Utils::Strings::loadAdditional( $lang );

		return sprintf( $strings->{$name}, @_) if $strings->{$name};
	}

	return Slim::Utils::Strings::string($name, @_);
}


# sortResultLoop
# sort the result loop $loop using field $field.
sub sortResultLoop {
	my $self     = shift;
	my $loop     = shift;
	my $field    = shift;

	if (defined ${$self->{'_results'}}{$loop}) {
		my @data;

		if ($field eq 'weight') {
			@data = sort { $a->{$field} <=> $b->{$field} } @{${$self->{'_results'}}{$loop}};
		} else {
			@data = sort { $a->{$field} cmp $b->{$field} } @{${$self->{'_results'}}{$loop}};
		}
		${$self->{'_results'}}{$loop} = \@data;
	}
}

sub isValidQuery {
	my $self = shift;
	return $self->{'_isQuery'};
}

sub getResults {
	my $self = shift;

	return $self->{'_results'};
}

sub setRawResults {
	my $self = shift;

	$self->{'_results'} = shift;
}

sub getResult {
	my $self = shift;
	my $key = shift || return;

	return ${$self->{'_results'}}{$key};
}

sub getResultLoopCount {
	my $self = shift;
	my $loop = shift;

	if (defined ${$self->{'_results'}}{$loop}) {
		return scalar(@{${$self->{'_results'}}{$loop}});
	}
}

sub getResultLoop {
	my $self = shift;
	my $loop = shift;
	my $loopidx = shift;
	my $key = shift || return undef;

	if (defined ${$self->{'_results'}}{$loop} &&
		defined ${$self->{'_results'}}{$loop}->[$loopidx]) {

			return ${${$self->{'_results'}}{$loop}->[$loopidx]}{$key};
	}
	return undef;
}

sub cleanResults {
	my $self = shift;

	my %resultHash;

	tie %resultHash, 'Tie::IxHash' if $self->{'_useixhash'};

	# not sure this helps release memory, but can't hurt
	delete $self->{'_results'};

	$self->{'_results'} = \%resultHash;

	# this will reset it to dispatchable so we can execute it once more
	$self->validate();
}


################################################################################
# Compound calls
################################################################################

# accepts a reference to an array containing references to arrays containing
# synonyms for the query names,
# and returns 1 if no name match the request. Used by functions implementing
# queries to check the dispatcher did not send them a wrong request.
# See Queries.pm for usage examples, for example infoTotalQuery.
sub isNotQuery {
	return !$_[0]->{'_isQuery'} || !$_[0]->__matchingRequest($_[1]);
}

# same for commands
sub isNotCommand {
	return $_[0]->{'_isQuery'} || !$_[0]->__matchingRequest($_[1]);
}

sub isCommand{
	return !$_[0]->{'_isQuery'} && $_[0]->__matchingRequest($_[1]);
}

sub isQuery{
	return $_[0]->{'_isQuery'} && $_[0]->__matchingRequest($_[1]);
}


# sets callback parameters (function and arguments) in a single call...
sub callbackParameters {
	my $self = shift;
	my $callbackf = shift;
	my $callbackargs = shift;

	$self->{'_cb_func'} = $callbackf;
	$self->{'_cb_args'} = $callbackargs;
}

# returns true if $param is undefined or not one of the possible values
# not really a method on request data members but defined as such since it is
# useful for command and queries implementation.
sub paramUndefinedOrNotOneOf {
	my $self = shift;
	my $param = shift;
	my $possibleValues = shift;

	return 1 if !defined $param;
	return 1 if !defined $possibleValues;
	return !grep($_ eq $param, @{$possibleValues});
}

# returns true if $param being defined, it is not one of the possible values
# not really a method on request data members but defined as such since it is
# useful for command and queries implementation.
sub paramNotOneOfIfDefined {
	my $self = shift;
	my $param = shift;
	my $possibleValues = shift;

	return 0 if !defined $param;
	return 1 if !defined $possibleValues;
	return !grep($_ eq $param, @{$possibleValues});
}

# not really a method on request data members but defined as such since it is
# useful for command and queries implementation.
sub normalize {
	my $self = shift;
	my $from = shift;
	my $numofitems = shift;
	my $count = shift;

	my $start = 0;
	my $end   = 0;
	my $valid = 0;

	$numofitems = $count if !defined $numofitems && defined $from;
	if ($numofitems && $count) {

		my $lastidx = $count - 1;

		if ($from > $lastidx) {
			return ($valid, $start, $end);
		}

		if ($from < 0) {
			$from = 0;
		}

		$start = $from;
		$end = $start + $numofitems - 1;

		if ($end > $lastidx) {
			$end = $lastidx;
		}

		$valid = 1;
	}

	return ($valid, $start, $end);
}


################################################################################
# Other
################################################################################

# execute the request
sub execute {
	my $self = shift;

	if (main::INFOLOG && $log->is_info) {
		$self->dump("Request");
	}

	main::PERFMON && (my $now = AnyEvent->time);

	# some time may have elapsed between the request creation
	# and its execution, and the client, f.e., could have disappeared
	# check all is OK once more...
	$self->validate();

	# do nothing if something's wrong
	if ($self->isStatusError()) {

		$log->error('Request in error, returning');

		return;
	}

	# call the execute function
	if (my $funcPtr = $self->{'_func'}) {

		# notify for commands
		# done here so that order of calls is maintained in all cases.
		if (!$self->query()) {

			push @notificationQueue, $self;
		}

		eval { &{$funcPtr}($self) };

		if ($@) {
			my $error = "$@";
			my $funcName = main::DEBUGLOG ? Slim::Utils::PerlRunTime::realNameForCodeRef($funcPtr) : 'unk';
			logError("While trying to run function coderef [$funcName]: [$error]");
			$self->setStatusBadDispatch();
			$self->dump('Request');
		}
	}

	# contine execution unless the Request is still work in progress (async)...
	$self->executeDone() unless $self->isStatusProcessing();

	main::PERFMON && $now && Slim::Utils::PerfMon->check('request', AnyEvent->time - $now, undef, $self->{'_func'});
}

# perform end of execution, calling the callback etc...
sub executeDone {
	my $self = shift;

	# perform the callback
	# do it unconditionally as it is used to generate the response web page
	# smart callback routines test the request status!
	$self->callback();

	if (!$self->isStatusDone()) {

		# remove the notification if we pushed it...
		my $notif = pop @notificationQueue;

		if ((defined $notif) && ($notif != $self)) {

			# oops wrong one, repush it...
			push @notificationQueue, $notif;
		}
	}

	if (main::DEBUGLOG && $log->is_debug) {

		$log->debug($self->dump('Request'));
	}
}

# allows re-calling the function. Basically a copycat of execute, without
# notification. This enables
sub jumpbacktofunc {
	my $self = shift;

	# do nothing if we're done
	if ($self->isStatusDone()) {

		logError('Called on done request, exiting');
		return;
	}

	# check we're still good
	$self->validate();

	# do nothing if something's wrong
	if ($self->isStatusError()) {

		logError('Called on done request, exiting');
		return;
	}

	# call the execute function
	if (my $funcPtr = $self->{'_func'}) {

		eval { &{$funcPtr}($self) };

		if ($@) {

			logError("While trying to run function coderef: [$@]");

			$self->setStatusBadDispatch();
			$self->dump('Request');
		}
	}

	# contine execution unless the Request is still work in progress (async)...
	$self->executeDone() unless $self->isStatusProcessing();
}

# perform callback if defined
sub callback {
	my $self = shift;

	# do nothing unless callback is enabled
	if ($self->callbackEnabled()) {

		if (defined(my $funcPtr = $self->callbackFunction())) {

			main::INFOLOG && $log->info("Calling callback function");

			my $args = $self->callbackArguments();

			# if we have no arg, use the request
			if (!defined $args) {

				eval { &$funcPtr($self) };

				if ($@) {
					logError("While trying to run function coderef: [$@]");
					$self->dump('Request');
				}

			# else use the provided arguments
			} else {

				eval { &$funcPtr(@$args) };

				if ($@) {
					logError("While trying to run function coderef: [$@]");
					$self->dump('Request');
				}
			}
		}

	} else {

		main::INFOLOG && $log->info("Callback disabled");
	}
}

# notify listeners...
sub notify {
	my $self = shift || return;
	my $specific = shift; # specific target of notify if we have a single known target

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug(sprintf("Notifying %s", $self->getRequestString()));
	}

	# process listeners if we match the super regexp (i.e. there is an interested listener)
	if ($self->{'_requeststr'} && $self->{'_requeststr'} =~ $listenerSuperRE) {

		my @l = values %listeners;
		for my $listener ( @l ) {
			next unless defined $listener;

			# skip unless we match the listener filter
			next unless $self->{'_requeststr'} =~ $listener->[0];

			my $notifyFuncRef = $listener->[1];
			my $clientid      = $listener->[3];

			# If this listener is client-specific, ignore unless we have that client
			if ( $clientid ) {
				next if !$self->clientid;

				my $client = $self->client() || next;

				# Bug 10064: playlist notifications get sent to everyone in the sync-group
				if ($self->isCommand([['playlist', 'newmetadata']])) {
					next if !grep($_->id eq $clientid, $client->syncGroupActiveMembers());
				} else {
					next if $self->clientid ne $clientid;
				}
			}

			if ( main::DEBUGLOG && $log->is_debug ) {
				my $funcName = $listener;

				if ( ref($notifyFuncRef) eq 'CODE' ) {
					$funcName = Slim::Utils::PerlRunTime::realNameForCodeRef($notifyFuncRef);
				}

				$log->debug(sprintf("Notifying %s of %s =~ %s",
									$funcName, $self->getRequestString, __filterString($listener->[2])
								   ));
			}

			main::PERFMON && (my $now = AnyEvent->time);

			eval { &$notifyFuncRef($self) };

			if ($@) {
				logError("Failed notify: $@");
			}

			main::PERFMON && Slim::Utils::PerfMon->check('notify', AnyEvent->time - $now, undef, $notifyFuncRef);
		}
	}

	# handle subscriptions
	# send the notification to all filters...
	for my $cnxid (keys %subscribers) {
		for my $name ($specific || keys %{$subscribers{$cnxid}}) {
			for my $clientid (keys %{$subscribers{$cnxid}{$name}}) {

				my $request = $subscribers{$cnxid}{$name}{$clientid};

				my $relevant = 1;

				if (defined(my $funcPtr = $request->autoExecuteFilter())) {

					$relevant = 0;

					if (ref($funcPtr) eq 'CODE') {

						eval { $relevant = &{$funcPtr}($request, $self) };

						if ($@) {
							my $funcName = main::DEBUGLOG ? Slim::Utils::PerlRunTime::realNameForCodeRef($funcPtr) : 'unk';
							logError("While trying to run function coderef [$funcName]: [$@]");

							next;
						}
					}
				}

				if ($relevant) {

					# delay answers by the amount returned by relevant-1
					Slim::Utils::Timers::killOneTimer($request,
						\&__autoexecute);

					Slim::Utils::Timers::setTimer($request,
						Time::HiRes::time() + $relevant - 1,
						\&__autoexecute);

#					$request->__autoexecute();
				}
			}
		}
	}
}


=head2 registerAutoExecute ( timeout, filterFunc )

Register ourself as subscribed to. Autoexecute after timeout
(if > 0) or if filterFunc returns 1 when sent notifications.

=cut
sub registerAutoExecute{
	my $self = shift || return;
	my $timeout = shift;
	my $filterFunc = shift;
	my $cleanupFunc = shift;

	main::DEBUGLOG && $log->debug("registerAutoExecute()");

	# we shall be a query
	return unless $self->{'_isQuery'};

	# we shall have a defined connectionID
	my $cnxid = $self->connectionID() || return;

	# requests with a client are remembered by client
	my $clientid = $self->clientid() || 'global';

	# requests are remembered by kind
	my $name = $self->getRequestString();

	# store the filterFunc in the request
	$self->autoExecuteFilter($filterFunc);

	# store cleanup function if it exists - this is called whenever the autoexecute is cancelled
	if ($cleanupFunc) {
		$self->autoExecuteCleanup($cleanupFunc);
	}

	# kill any previous subscription we might have laying around
	# (for this query/client/connection)
	my $oldrequest = $subscribers{$cnxid}{$name}{$clientid};

	if (defined $oldrequest) {

		main::INFOLOG && $log->info("Old friend: $cnxid - $name - $clientid");

		delete $subscribers{$cnxid}{$name}{$clientid};

		# call old cleanup if it exists and is different from the cleanup for new request
		if (my $cleanup = $oldrequest->autoExecuteCleanup()) {
			if (!$cleanupFunc || $cleanupFunc != $cleanup) {
				eval { &{$cleanup}($oldrequest, $cnxid) };
			}
		}

		Slim::Utils::Timers::killTimers($oldrequest, \&__autoexecute);
	}
	else {
		main::INFOLOG && $log->info("New buddy: $cnxid - $name - $clientid");
	}

	# store the new subscription if this is what is asked of us
	if ($timeout ne '-') {

		main::DEBUGLOG && $log->debug(".. set ourself up");

		# copy the request
		my $request = $self->virginCopy();

		$subscribers{$cnxid}{$name}{$clientid} = $request;

		if ($timeout > 0) {
			main::DEBUGLOG && $log->debug(".. starting timer: $timeout");
			# start the timer
			Slim::Utils::Timers::setTimer($request,
				Time::HiRes::time() + $timeout,
				\&__autoexecute);
		}
	}
}

=head2 fixencoding ( )

Handle encoding for external commands.

=cut
sub fixEncoding {
	my $self = shift || return;

	map { utf8::decode($_) unless !defined($_) || ref $_ || utf8::is_utf8($_)} values %{$self->{'_params'} };
}

################################################################################
# Legacy
################################################################################
# support for legacy applications

# perform the same feat that the old execute: array in, array out
sub executeLegacy {
	my $client = shift;
	my $parrayref = shift;

	# create a request from the array - using ixhashes so renderAsArray works
	my $request = Slim::Control::Request->new(
		(blessed($client) ? $client->id() : undef),
		$parrayref,
		1,
	);

	if (defined $request) {

		if ($request->{'_status'} == 1) {

			$request->execute();
		}

		return $request->renderAsArray;
	}
}

# returns the request as an array
sub renderAsArray {
	my $self = shift;

	if (main::INFOLOG && $log->is_info && !$self->{'_useixhash'}) {
		logBacktrace("request should set useIxHashes in Slim::Control::Request->new()");
	}

	my @returnArray;

	# conventions:
	# -- parameter or result with key starting with "_": value outputted
	# -- parameter or result with key starting with "__": no output
	# -- result starting with key ending in "_loop": is a loop
	# -- anything else: output "key:value"

	# push the request terms
	push @returnArray, @{$self->{'_request'}};

	# push the parameters
	while (my ($key, $val) = each %{$self->{'_params'}}) {

		# no output
		next if ($key =~ /^__/);

		if ($key =~ /^_/) {
			push @returnArray, $val;
		} else {
			push @returnArray, ($key . ":" . $val);
		}
 	}

 	# push the results
	while (my ($key, $val) = each %{$self->{'_results'}}) {

		# no output
		next if ($key =~ /^__/);

		# loop
		if ($key =~ /_loop$/) {

			# loop over each elements
			foreach my $hash (@{${$self->{'_results'}}{$key}}) {

				while (my ($key2, $val2) = each %{$hash}) {

					if ($key2 =~ /^__/) {
						# no output
					} elsif ($key2 =~ /^_/) {
						push @returnArray, $val2;
					} else {
						push @returnArray, ($key2 . ':' . $val2);
					}
				}
			}
			next;
		}

		# array unrolled
		if (ref $val eq 'ARRAY') {
			$val = join (',', @{$val})
		}

		if ($key =~ /^_/) {
			push @returnArray, $val;
		} else {
			push @returnArray, ($key . ':' . $val);
		}
 	}

	return @returnArray;
}

################################################################################
# Utility function to dump state of the request object to stdout
################################################################################
sub dump {
	my $self = shift;
	my $introText = shift || '?';

	my $str = $introText . ": ";

	if ($self->query()) {
		$str .= 'Query ';
	} else {
		$str .= 'Command ';
	}

	if (my $client = $self->client()) {
		my $clientid = $client->id();
		$str .= "[$clientid->" . $self->getRequestString() . "]";
	} else {
		$str .= "[" . $self->getRequestString() . "]";
	}

	if ($self->callbackFunction()) {

		if ($self->callbackEnabled()) {
			$str .= " cb+ ";
		} else {
			$str .= " cb- ";
		}
	}

	if ($self->source()) {
		$str .= " from " . $self->source() ." ";
	}

	$str .= ' (' . $self->getStatusText() . ")";

	main::INFOLOG && $log->info($str);

	while (my ($key, $val) = each %{$self->{'_params'}}) {

			main::INFOLOG && $log->info("   Param: [$key] = ", (defined $val ? "[$val]" : 'undef'));
 	}

	while (my ($key, $val) = each %{$self->{'_results'}}) {

		if ($key =~ /_loop$/) {

			my $count = scalar @{${$self->{'_results'}}{$key}};

			main::INFOLOG && $log->info("   Result: [$key] is loop with $count elements:");

			# loop over each elements
			for (my $i = 0; $i < $count; $i++) {

				my $hash = ${$self->{'_results'}}{$key}->[$i];

				if (ref($hash) eq 'HASH') {

					while (my ($key2, $val2) = each %{$hash}) {
						main::INFOLOG && $log->info("   Result:   $i. [$key2] = [", (ref $val2 ? Data::Dump::dump($val2) : $val2), "]");
					}

				}

				else {

					main::INFOLOG && $log->info('   Result:   ' . Data::Dump::dump($hash));

				}
			}

		} else {
			main::INFOLOG && $log->info("   Result: [$key] = [", (ref $val ? Data::Dump::dump($val) : $val), "]");
		}
 	}
}

################################################################################
# Private methods
################################################################################

# this is hot so optimised for speed
sub __matchingRequest {
	# $_[0] = self
	# $_[1] = possibleNames in the form of an arrayref of arrayrefs
	my $request = $_[0]->{'_request'};
	my $i = 0;

	for my $names (@{$_[1]}) {
		my $req = $request->[$i++];
		if (!$req || !grep($_ eq $req, @$names)) {
			return 0;
		}
	}

	return 1;
}

# return compiled regexp representing the $possibleNames array of arrays
sub __requestRE {
	my $possibleNames = shift || return qr /./;
	my @reParts = ();

	for my $names (@$possibleNames) {

		# Bracket each name using word boundaries to avoid
		# "play" matching "play", "playlist", and "display".

		if (scalar @$names) {
			push @reParts,
				'(?:' . join('|', map { "\\b$_\\b" } @$names) . ')';
		}
	}

	my $re = join(',', @reParts);
	return qr /$re/;
}

# update the super filter used by notify
# this builds a regexp matching any of the first level verbs the listeners are interested in
# or /./ if there is a listener with no requestRef filter specified
sub __updateListenerSuperRE {

	my %names;
	my $regexp;

	for my $listener (values %listeners) {

		my $requestsRef = $listener->[2];

		if (!defined $requestsRef) {
			$regexp = '.';
			last;
		}

		map { $names{$_} = 1 } @{$requestsRef->[0]};
	}

	$regexp ||= join('|', keys %names);

	$listenerSuperRE = qr /$regexp/;

	main::DEBUGLOG && $log->debug("updated listener superRE: $listenerSuperRE");
}

# returns a string corresponding to the notification filter, used for
# debugging
sub __filterString {
	my $requestsRef = shift;

	if (!defined $requestsRef) {

		return "(no filter)";
	}

	my $str = "[";

	foreach my $req (@$requestsRef) {
		$str .= "[";
		my @list = map { "\'$_\'" } @$req;
		$str .= join(",", @list);
		$str .= "]";
	}

	$str .= "]";
}

# callback for the subscriptions.
sub __autoexecute{
	my $self = shift;

	main::DEBUGLOG && $log->debug("__autoexecute()");

	# we shall have somewhere to callback to
	my $funcPtr = $self->autoExecuteCallback() || return;

	return unless ref($funcPtr) eq 'CODE';

	# we shall have a connection id to send as param
	my $cnxid = $self->connectionID() || return;

	# delete the sub in case of error
	my $deleteSub = 0;

	# execute ourself after some cleanup
	$self->cleanResults;
	$self->execute();

	if ($self->isStatusError()) {
		$deleteSub = 1;
	}

	# execute the callback in all cases.
	eval { &{$funcPtr}($self, $cnxid) };

	# oops, failed
	if ($@) {
		my $funcName = main::DEBUGLOG ? Slim::Utils::PerlRunTime::realNameForCodeRef($funcPtr) : 'unk';
		logError("While trying to run function coderef [$funcName]: [$@] => deleting subscription");
		$deleteSub = 1;
	}

	if ($deleteSub) {
		my $name = $self->getRequestString();
		my $clientid = $self->clientid() || 'global';
		my $request2del = delete $subscribers{$cnxid}{$name}{$clientid};
		main::DEBUGLOG && $log->debug("__autoexecute: deleting $cnxid - $name - $clientid");
		if (my $cleanup = $self->autoExecuteCleanup()) {
			eval { &{$cleanup}($self, $cnxid) };
		}
		# there should not be any of those, but just to be sure
		Slim::Utils::Timers::killTimers($self, \&__autoexecute);
		Slim::Utils::Timers::killTimers($request2del, \&__autoexecute);
	}

}

=head1 SEE ALSO

=cut

1;

__END__
