#########################################################################
# many scarry english charz
# eAthena, packet_db.txt, 22.04.07: 2007-02-12aSakexe, packet_ver: 21
# v1
# junk-edition!
#########################################################################

package Network::Send::ServerType8_2;

use strict;
use Globals qw($accountID $sessionID $sessionID2 $accountSex $char $charID %config %guild @chars $masterServer $syncSync $net);
use Network::Send::ServerType8;
use base qw(Network::Send::ServerType8);
use Log qw(message warning error debug);
use I18N qw(stringToBytes);
use Utils qw(getTickCount getHex getCoordString);

sub new {
	my ($class) = @_;
	return $class->SUPER::new(@_);
}


######################################
#  Junk Generaor by LabMouse  #
######################################
sub junk {
   my ($arg1, @args) = @_;
   my ($lv4, $i, $tmp) = 0;
   my $res;
   $lv4 = $arg1;
   if ($lv4 == 0) {
      $lv4 = 4;
   }
   $tmp = rand 15;
   if ($tmp > 9) {
      $tmp = ($tmp - 9) + 0x61;
      $tmp = $tmp & 0xFF;
   } else {
      $tmp = $tmp + 0x30;
      $tmp = $tmp & 0xFF;
   }
   $res = pack("C", $tmp);

   for ($i = 1; $i < ($lv4 - 1); ++$i) {
      $tmp = rand 15;
      if ($tmp > 9) {
         $tmp = ($tmp - 9) + 0x60;
         $tmp = $tmp & 0xFF;
      } else {
         $tmp = $tmp + 0x30;
         $tmp = $tmp & 0xFF;
      }
      $res .= pack("C", $tmp);
   }
   $res = $res . pack("C", 0x00);
   return $res;
}
####################### 


sub sendMasterLogin {
	my ($self, $username, $password, $master_version, $version) = @_;
	my $msg = pack("v1 V", hex($masterServer->{masterLogin_packet}) || 0x0064, $version) .
		pack("a24", $username) .
		pack("a24", $password) .
		pack("C", $master_version);
	$self->sendToServer($msg);
}


sub sendAttack {
	my ($self, $monID, $flag) = @_;
	
	my %args;
	$args{monID} = $monID;
	$args{flag} = $flag;
	Plugins::callHook('packet_pre/sendAttack', \%args);
	if ($args{return}) {
		$self->sendToServer($args{msg});
		return;
	}

	#0x0190,19,actionrequest,5:18
	my $msg = pack("C*", 0x90, 0x01) . junk(3) . $monID . junk(9) . pack("C1", $flag);
	$self->sendToServer($msg);
	debug "Sent attack: ".getHex($monID)."\n", "sendPacket", 2;
}

sub sendChat {
	my ($self, $message) = @_;
	$message = "|00$message" if ($config{chatLangCode} && $config{chatLangCode} ne "none");

	my ($data, $charName); # Type: Bytes
	$message = stringToBytes($message); # Type: Bytes
	$charName = stringToBytes($char->{name});

	#0x00f3,-1,globalmessage,2:4
	$data = pack("C*", 0xF3, 0x00) .
			pack("v*", length($charName) + length($message) + 8) .
			$charName . " : " . $message . chr(0);
	$self->sendToServer($data);
}

sub sendDrop {
	my ($self, $index, $amount) = @_;
	
	#0x0116,10,dropitem,5:8
	my $msg = pack("C*", 0x16, 0x01) . junk(3) .pack("v*", $index) . pack("x1") . pack("v*", $amount);

	$self->sendToServer($msg);
	debug "Sent drop: $index x $amount\n", "sendPacket", 2;
}

sub sendGetCharacterName {
	my ($self, $ID) = @_;

	#0x00a2,15,solvecharname,11
	my $msg = pack("C*", 0xA2, 0x00) . junk(9) . $ID;
	$self->sendToServer($msg);
	debug "Sent get character name: ID - ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendGetPlayerInfo {
	my ($self, $ID) = @_;
	
	#0x008c,11,getcharnamerequest,7
	my $msg = pack("C*", 0x8C, 0x00) . junk(5) . $ID;
	$self->sendToServer($msg);
	debug "Sent get player info: ID - ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendItemUse {
	my ($self, $ID, $targetID) = @_;
	
	#0x009f,14,useitem,4:10
	my $msg = pack("C*", 0x9F, 0x00) . junk(2) . pack("v*", $ID) . junk(4) . $targetID;
	$self->sendToServer($msg);
	debug "Item Use: $ID\n", "sendPacket", 2;
}

sub sendLook {
	my ($self, $body, $head) = @_;
	
	#0x0085,11,changedir,7:10
	my $msg = pack("C*", 0x85, 0x00) . junk(5) . pack("C*", $head) . pack("x1") .pack("x1") . pack("C*", $body);

	$self->sendToServer($msg);
	debug "Sent look: $body $head\n", "sendPacket", 2;
	$char->{look}{head} = $head;
	$char->{look}{body} = $body;
}

sub sendMapLogin {
	my ($self, $accountID, $charID, $sessionID, $sex) = @_;
	$sex = 0 if ($sex > 1 || $sex < 0); # Sex can only be 0 (female) or 1 (male)

	#0x009b,26,wanttoconnection,4:9:17:18:25
	my $msg = pack("C*", 0x9B, 0) . junk(2) .
		$accountID . pack("x1") .
		$charID . junk(4) . 
		$sessionID .
		pack("V", getTickCount()) .
		pack("C*", $sex);

	$self->sendToServer($msg);
}

sub sendMove {
	my $self = shift;
	my $x = int scalar shift;
	my $y = int scalar shift;

	#0x00a7,8,walktoxy,5
	my $msg = pack("C*", 0xA7, 0x00) . junk(3) . getCoordString($x, $y, 1);
	$self->sendToServer($msg);
	debug "Sent move to: $x, $y\n", "sendPacket", 2;
}


sub sendSit {
	my $self = shift;
	
	my %args;
	$args{flag} = 2;
	Plugins::callHook('packet_pre/sendSit', \%args);
	if ($args{return}) {
		$self->sendToServer($args{msg});
		return;
	}

	#0x0190,19,actionrequest,5:18
	my $msg = pack("C*", 0x90, 0x01) . junk(3) . pack("V*", 0) . junk(9) . pack("C1", 0x02);

	$self->sendToServer($msg);
	debug "Sitting\n", "sendPacket", 2;
}

sub sendStand {
	my $self = shift;

	my %args;
	$args{flag} = 3;
	Plugins::callHook('packet_pre/sendStand', \%args);
	if ($args{return}) {
		$self->sendToServer($args{msg});
		return;
	}	

	#0x0190,19,actionrequest,5:18
	my $msg = pack("C*", 0x90, 0x01) . junk(3) . pack("V*", 0) . junk(9) . pack("C1", 0x03);

	$self->sendToServer($msg);
	debug "Standing\n", "sendPacket", 2;
}

sub sendSkillUse {
	my $self = shift;
	my $ID = shift;
	my $lv = shift;
	my $targetID = shift;
	
	my %args;
	$args{ID} = $ID;
	$args{lv} = $lv;
	$args{targetID} = $targetID;
	Plugins::callHook('packet_pre/sendSkillUse', \%args);
	if ($args{return}) {
		$self->sendToServer($args{msg});
		return;
	}

	#0x0072,25,useskilltoid,6:10:21
	my $msg = pack("C*", 0x72, 0x00) . junk(4) . pack("v*", $lv) . junk(2) . pack("v*", $ID) . junk(9) . $targetID;

	$self->sendToServer($msg);
	debug "Skill Use: $ID\n", "sendPacket", 2;
}

sub sendSkillUseLoc {
	my ($self, $ID, $lv, $x, $y) = @_;
	
	#0x0113,22,useskilltopos,5:9:12:20
	my $msg = pack("C*", 0x13, 0x01) . junk(3) . pack("v*", $lv) . junk(2) . pack("v*", $ID) . pack("x1") .
		pack("v*", $x) . pack("C*", 0xF1 + rand 10, 0x0B + rand 6) .pack("C*", 0x5B, 0x4E, 0xB4, 0x76) . pack("v*", $y);

	$self->sendToServer($msg);
	debug "Skill Use on Location: $ID, ($x, $y)\n", "sendPacket", 2;
}

sub sendStorageAdd {
	my $self= shift;
	my $index = shift;
	my $amount = shift;

	#0x0094,14,movetokafra,7:10
	my $msg = pack("C*", 0x94, 0x00) . junk(5) . pack("v*", $index) . pack("x1") . pack("V*", $amount);
	$self->sendToServer($msg);
	debug "Sent Storage Add: $index x $amount\n", "sendPacket", 2;
}

sub sendStorageGet {
	my ($self, $index, $amount) = @_;

	#0x00f7,22,movefromkafra,14:18
	my $msg = pack("C*", 0xF7, 0x00) . junk(12) . pack("v*", $index) . junk(2) . pack("V*", $amount);
	$self->sendToServer($msg);
	debug "Sent Storage Get: $index x $amount\n", "sendPacket", 2;
}

sub sendStorageClose {
	my ($self) = @_;

	#0x0193,2,closekafra,0
	my $msg = pack("C*", 0x93, 0x01);
	$self->sendToServer($msg);
	debug "Sent Storage Done\n", "sendPacket", 2;
}

sub sendSync {
	my ($self, $initialSync) = @_;
	my $msg;
	# XKore mode 1 lets the client take care of syncing.
	return if ($self->{net}->version == 1);

	$syncSync = pack("V", getTickCount());
	
	#0x0089,8,ticksend,4
	#.mod altsync:
	if (($config{uaROmod} == 1) && ($config{uaROmodAltSync} == 1)) {
		my $msg = pack("C*", 0x4D, 0x01);
	} else {
		my $msg = pack("C*", 0x89, 0x00) . junk(2). $syncSync;
	}
	$self->sendToServer($msg);
	debug "Sent Sync\n", "sendPacket", 2;
}

sub sendTake {
	my $self = shift;
	my $itemID = shift; # $itemID = long
	
	my $msg = pack("C*", 0xF5, 0x00) . junk(2) . $itemID;
	$self->sendToServer($msg);
	debug "Sent take\n", "sendPacket", 2;
}

1;
