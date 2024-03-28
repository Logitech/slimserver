/*
 * Globally used Lyrion Music Server strings.
 * This file should be PROCESSed if SqueezeJS.UI is used.
 */
[% PROCESS jsString id='POWER' jsId='' %]
[% PROCESS jsString id='PLAY' jsId='' %]
[% PROCESS jsString id='PAUSE' jsId='' %]
[% PROCESS jsString id='NEXT' jsId='' %]
[% PROCESS jsString id='PREVIOUS' jsId='' %]
[% PROCESS jsString id='CONNECTING_FOR' jsId='' %]

[% PROCESS jsString id='SHUFFLE' jsId='' %]
[% PROCESS jsString id='SHUFFLE_OFF' jsId='shuffle0' %]
[% PROCESS jsString id='SHUFFLE_ON_SONGS' jsId='shuffle1' %]
[% PROCESS jsString id='SHUFFLE_ON_ALBUMS' jsId='shuffle2' %]

[% PROCESS jsString id='REPEAT' jsId='' %]
[% PROCESS jsString id='REPEAT_OFF' jsId='repeat0' %]
[% PROCESS jsString id='REPEAT_ONE' jsId='repeat1' %]
[% PROCESS jsString id='REPEAT_ALL' jsId='repeat2' %]

[% PROCESS jsString id='VOLUME' jsId='volume' %]
SqueezeJS.Strings['volume'] += '[% stringCOLON %]';
[% PROCESS jsString id='VOLUME_LOUDER' jsId='volumeup' %]
[% PROCESS jsString id='VOLUME_SOFTER' jsId='volumedown' %]

[% PROCESS jsString id='BY' jsId='' %]
[% PROCESS jsString id='FROM' jsId='' %]
[% PROCESS jsString id='COLON' jsId='colon' %]
[% PROCESS jsString id='ON' jsId='on' %]
[% PROCESS jsString id='OFF' jsId='off' %]
[% PROCESS jsString id='YES' jsId='' %]
[% PROCESS jsString id='NO' jsId='' %]

[% PROCESS jsString id='ALBUM' jsId='' %]
[% PROCESS jsString id='ARTIST' jsId='' %]
[% PROCESS jsString id='YEAR' jsId='' %]
[% PROCESS jsString id='WORKS' jsId='' %]

[% PROCESS jsString id='CLOSE' jsId='' %]
[% PROCESS jsString id='CANCEL' jsId='' %]
[% PROCESS jsString id='CHOOSE_PLAYER' jsId='' %]
[% PROCESS jsString id='SYNCHRONIZE' jsId='' %]
[% PROCESS jsString id='SETUP_SYNCHRONIZE_DESC' jsId='' %]
[% PROCESS jsString id='SETUP_NO_SYNCHRONIZATION' jsId='' %]
[% PROCESS jsString id='NO_PLAYER_FOUND' jsId='no_player' %]
[% PROCESS jsString id='NO_PLAYER_DETAILS' jsId='' %]
[% PROCESS jsString id='SQUEEZEBOX_SERVER' %]
[% PROCESS jsString id='SQUEEZEBOX_SERVER_WANT_SWITCH' jsId='sc_want_switch' %]
[% PROCESS jsString id='BROWSE' jsId='' %]
[% PROCESS jsString id='SETUP_SELECT_FOLDER' jsId='choose_folder' %]
[% PROCESS jsString id='SETUP_SELECT_FILE' jsId='choose_file' %]

if (Ext.MessageBox) {
	Ext.MessageBox.buttonText.yes = '[% "YES" | string %]';
	Ext.MessageBox.buttonText.no = '[% "NO" | string %]';
	Ext.MessageBox.buttonText.cancel = '[% "CANCEL" | string %]';
}
