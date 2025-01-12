#########################################################################
#  OpenKore - Network subsystem
#  This module contains functions for sending messages to the server.
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#########################################################################
#
#  ServerType for rRO and vRO
#  27 December 2006: Updated to support 2006-12-18a protocol
#  19 January  2007: Updated to support 2007-01-16a protocol
#  13 February 2007: vRO now also uses this server type.
#  07 March    2007: Updated to support rRO 2007-02-26a protocol, vRO is disabled
#  23 March    2007: Updated to support rRO 2007-02-26e protocol
#  12 April    2007: Updated to support rRO 2007-04-10a protocol
#
#########################################################################
package Network::Send::ServerType13;

use strict;
use Network::Send::ServerType0;
use base qw(Network::Send::ServerType0);
use Globals qw($accountID $sessionID $sessionID2 $accountSex $char $charID %config %guild @chars $masterServer $syncSync);
use Log qw(error debug);
use I18N qw(stringToBytes);
use Utils;

sub new {
	my ($class) = @_;
	return $class->SUPER::new(@_);
}

sub sendAttack {
	my ($self, $monID, $flag) = @_;
	my $msg;
	my %args;
	$args{monID} = $monID;
	$args{flag} = $flag;
	Plugins::callHook('packet_pre/sendAttack', \%args);
	if ($args{return}) {
		$self->sendToServer($args{msg});
		return;
	}

	error "Your server is not supported because it uses padded packets.\n";
	if (AI::action() eq "NPC") {
		error "Failed to talk to monster NPC.\n";
		AI::dequeue();
	} elsif (AI::action() eq "attack") {
		error "Failed to attack target.\n";
		AI::dequeue();
	}

	$self->sendToServer($msg);
	debug "Sent attack: ".getHex($monID)."\n", "sendPacket", 2;
}

sub sendChat {
	my ($self, $message) = @_;
	$message = "|00$message" if ($config{chatLangCode} && $config{chatLangCode} ne "none");
	my ($data, $charName); # Type: Bytes
	$message = stringToBytes($message); # Type: Bytes
	$charName = stringToBytes($char->{name});
	$data = pack("C*", 0x7E, 0x00) . pack("v*", length($charName) + length($message) + 8) . $charName . " : " . $message . chr(0);
	$self->sendToServer($data);
	#debug bla-bla-bla not found! - pJ
}

sub sendDrop {
	my ($self, $index, $amount) = @_;
	my $msg;
	$msg = pack("C*", 0x93, 0x01) . pack("v1", $index). pack("v1", $amount) ;
	$self->sendToServer($msg);
	debug "Sent drop: $index x $amount\n", "sendPacket", 2;
}

sub sendGetCharacterName {
	my ($self, $ID) = @_;
	my $msg;
	$msg = pack("C*", 0x9B, 0x00) . $ID . pack("x3") ; 
	$self->sendToServer($msg);
	debug "Sent get character name: ID - ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendGetPlayerInfo {
	my ($self, $ID) = @_;
	my $msg;
	$msg = pack("C*", 0x8C, 0x00) . pack("x2"). $ID; 
	$self->sendToServer($msg);
	debug "Sent get player info: ID - ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendItemUse {
	my $self = shift;
	my $ID = shift;
	my $targetID = shift;
	my $msg;
	$msg = pack("C*", 0xF5, 0x00) . pack("v", $ID) . $targetID;
	$self->sendToServer($msg);
	debug "Item Use: $ID\n", "sendPacket", 2;
}

sub sendLook {
	my ($self, $body, $head) = @_;
	my $msg;
	$msg = pack("C*", 0x16, 0x01) . pack("C*", $head, 0, $body);
	$self->sendToServer($msg);
	debug "Sent look: $body $head\n", "sendPacket", 2;
	$char->{look}{head} = $head;
	$char->{look}{body} = $body;
}

sub sendMapLogin {
	my $self = shift;
	my $accountID = shift;
	my $charID = shift;
	my $sessionID = shift;
	my $sex = shift;
	my $msg;
	$sex = 0 if ($sex > 1 || $sex < 0); # Sex can only be 0 (female) or 1 (male)
	$msg = pack("C*", 0x94, 0x00). $charID. $sessionID . pack("x2")  . $accountID .  pack("x6")  .  pack("V", getTickCount()) . pack("x3") . pack("C*", $sex);
	$self->sendToServer($msg);
}

sub sendMove {
	my $self = shift;
	my $x = int scalar shift;
	my $y = int scalar shift;
	my $msg;
	$msg = pack("C*", 0xA2, 0x00) . pack("x9") . getCoordString($x, $y, 1); 
	$self->sendToServer($msg);
	debug "Sent move to: $x, $y\n", "sendPacket", 2;
}

sub sendSit {
	my $self = shift;
	my $msg;

	my %args;
	$args{flag} = 2;
	Plugins::callHook('packet_pre/sendSit', \%args);
	if ($args{return}) {
		$self->sendToServer($args{msg});
		return;
	}

	error "Your server is not supported because it uses padded packets.\n";
	if (AI::action() eq "sitting") {
		error "Failed to sit.\n";
		AI::dequeue();
	}
	return;

	$self->sendToServer($msg);
	debug "Sitting\n", "sendPacket", 2;
}

sub sendSkillUse {
	my $self = shift;
	my $ID = shift;
	my $lv = shift;
	my $targetID = shift;
	my $msg;
	
	my %args;
	$args{ID} = $ID;
	$args{lv} = $lv;
	$args{targetID} = $targetID;
	Plugins::callHook('packet_pre/sendSkillUse', \%args);
	if ($args{return}) {
		$self->sendToServer($args{msg});
		return;
	}
	
	error "Your server is not supported because it uses padded packets.\n";
	if (AI::action() eq 'teleport') {
		error "Failed to use teleport skill.\n";
		AI::dequeue();
	} elsif (AI::action() ne "skill_use") {
		error "Failed to use skill.\n";
		AI::dequeue();
	}
	return;
	
	$self->sendToServer($msg);
	debug "Skill Use: $ID\n", "sendPacket", 2;
}

sub sendSkillUseLoc {
	my ($self, $ID, $lv, $x, $y) = @_;
	my $msg;
	$msg = pack("C*", 0xF3, 0x00) . pack("v", $lv) . pack("x8") . pack("v*", $ID) . pack("v*", $x) . pack("v*", $y);
	$self->sendToServer($msg);
	debug "Skill Use on Location: $ID, ($x, $y)\n", "sendPacket", 2;
}

sub sendStorageAdd {
	my $self = shift;
	my $index = shift;
	my $amount = shift;
	my $msg;
	$msg = pack("C*", 0x13, 0x01) . pack("x1") . pack("V", $amount) . pack("v", $index);
	$self->sendToServer($msg);
	debug "Sent Storage Add: $index x $amount\n", "sendPacket", 2;
}

sub sendStorageClose {
	my ($self) = @_;
	my $msg;
	$msg = pack("C*", 0x72, 0x00);
	$self->sendToServer($msg);
	debug "Sent Storage Done\n", "sendPacket", 2;
}

sub sendStorageGet {
	my $self = shift;
	my $index = shift;
	my $amount = shift;
	my $msg;
	$msg = pack("C*", 0xF7, 0x00) . pack("v", $index) . pack("V*", $amount) . pack("x1");
	$self->sendToServer($msg);
	debug "Sent Storage Get: $index x $amount\n", "sendPacket", 2;
}

sub sendStand {
	my $self = shift;
	my $msg;

	my %args;
	$args{flag} = 3;
	Plugins::callHook('packet_pre/sendStand', \%args);
	if ($args{return}) {
		$self->sendToServer($args{msg});
		return;
	}

	error "Your server is not supported because it uses padded packets.\n";
	if (AI::action() eq "standing") {
		error "Failed to stand.\n";
		AI::dequeue();
	}
	return;
		
	$self->sendToServer($msg);
	debug "Standing\n", "sendPacket", 2;
}

sub sendSync {
	my ($self, $initialSync) = @_;
	my $msg;
	# XKore mode 1 lets the client take care of syncing.
	return if ($self->{net}->version == 1);

	$syncSync = pack("V", getTickCount());
	$msg = pack("C*", 0xA7, 0x00). pack("x9") . $syncSync . pack("x5"); 
	$self->sendToServer($msg);
	debug "Sent Sync\n", "sendPacket", 2;
}

sub sendTake {
	my $self = shift;
	my $itemID = shift; # $itemID = long
	my $msg;
	$msg = pack("C*", 0x9F, 0x00) . $itemID;
	$self->sendToServer($msg);
	debug "Sent take\n", "sendPacket", 2;
}

1;
