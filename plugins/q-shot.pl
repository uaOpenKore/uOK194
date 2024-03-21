# ==============================
# Screenshot plugin for Openkore
# ==============================
# by Kissa2k aka F[i]ghter (night.fighter.2005 <SABAKA> gmail.com)
# 
# mod --> xquit
# mod --> screenshot
#
# 'Zdies byli 4orT i piroJOKE'
#

package screenshot;

use strict;
use Plugins;
use Log qw(message warning error debug);
use Globals;
use Win32::GuiTest;

my $ID;

my $clientWindowsName = "R0";


sub Reload {
	Unload();
}

sub Unload {
	Commands::unregister($ID);
}


Plugins::register('qShot', 'Allow to create screenshots in XKore mode, etc', \&Unload, \&Reload);


my $ID = Commands::register(
    ["screenshot", "Makes a screenshots whith active XKore mode", \&screen],
    ["xquit", "Close ro-client window whith active XKore mode", \&xquit],
);


sub sendKey {
	my $key = shift;
	
	my @windows = Win32::GuiTest::FindWindowLike(0, "^".$clientWindowsName);
	foreach (@windows) {
		Win32::GuiTest::ShowWindow($_, '1'); #SW_MAXIMIZE
		Win32::GuiTest::SetForegroundWindow($_);
		Win32::GuiTest::SendKeys($key);
	}
	message "Done.\n";
}

sub screen {
	if(Win32::GuiTest::FindWindowLike(0, "^".$clientWindowsName) && $config{XKore}==1) {
		message "Saving screenshot...\n";
		sendKey("{PRTSCR}");
	} else{
		warning "\tYou are not in XKore 1 mode!\n\tScreenshots are available in XKore 1 mode only!\n";
	}
}

sub xquit {
	if(Win32::GuiTest::FindWindowLike(0, "^".$clientWindowsName) && $config{XKore}==1) {
		message "Closing client window...\n";
		sendKey("%{F4}");
	} else{
		warning "\tYou are not in XKore 1 mode!\n\tClosing client window are available in XKore 1 mode only!\n";
	}
}

1;
