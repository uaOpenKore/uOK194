package Macro::Automacro;

use strict;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(releaseAM lockAM automacroCheck consoleCheckWrapper);
our @EXPORT = qw(checkVar checkVarVar checkLoc checkLevel checkLevel checkClass
	checkPercent checkStatus checkItem checkPerson checkCond checkEquip checkCast
	checkEquip checkMsg checkMonster checkAggressives checkConsole checkMapChange
	checkNotMonster);

use Utils;
use Globals;
use Skill;
use AI;
use Log qw(message error warning);
use Macro::Data;
use Macro::Utilities qw(between cmpr match getArgs setVar getVar refreshGlobal
	getPlayerID getSoldOut getInventoryAmount getCartAmount getShopAmount
	getStorageAmount callMacro);

our $Changed = sprintf("%s %s %s",
	q$Date: 2007-03-23 03:56:48 +0200 (Пт, 23 мар 2007) $
	=~ /(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ([+-]\d{4})/);

# check for variable #######################################
sub checkVar {
	$cvs->debug("checkVar(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $arg = shift;
	my ($var, $cond, $val) = getArgs($arg);

	if ($cond eq "unset") {return exists $varStack{$var}?0:1}

	refreshGlobal($var);

	if (exists $varStack{$var}) {
		return cmpr($varStack{$var}, $cond, $val)
	} else {
		return $cond eq "!="
	}
}

# check for a variable's variable ##########################
sub checkVarVar {
	$cvs->debug("checkVarVar(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $arg = shift;
	my ($varvar, $cond, $val) = getArgs($arg);

	if ($cond eq "unset") {return exists $varStack{"#".$varStack{$varvar}}?0:1}

	if (exists $varStack{"#".$varStack{$varvar}}) {
		$arg =~ s/$varvar/"#$varStack{$varvar}"/g;
		return checkVar($arg)
	} else {
		return $cond eq "!="
	}
}

# checks for location ######################################
# parameter: map [x1 y1 [x2 y2]]
# note: when looking in the default direction (north)
# x1 < x2 and y1 > y2 where (x1|y1)=(upper left) and
#                           (x2|y2)=(lower right)
# uses: calcPosition (Utils?)
sub checkLoc {
	$cvs->debug("checkLoc(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $arg = shift;
	if ($arg =~ /,/) {
		my @locs = split(/\s*,\s*/, $arg);
		foreach my $l (@locs) {return 1 if checkLoc($l)}
		return 0
	}
	my $not = 0;
	if ($arg =~ /^not /) {$not = 1; $arg =~ s/^not //g}
	my ($map, $x1, $y1, $x2, $y2) = split(/ /, $arg);
	if ($map eq $field{name}) {
		if ($x1 && $y1) {
			my $pos = calcPosition($char);
			return 0 unless defined $pos->{x} && defined $pos->{y};
			if ($x2 && $y2) {
				if (between($x1, $pos->{x}, $x2) && between($y2, $pos->{y}, $y1)) {
					return $not?0:1
				}
				return $not?1:0
			}
			if ($x1 == $pos->{x} && $y1 == $pos->{y}) {
				return $not?0:1
			}
			return $not?1:0
		}
		return $not?0:1
	}
	return $not?1:0
}

# checks for base/job level ################################
# uses cmpr (Macro::Utils)
sub checkLevel {
	$cvs->debug("checkLevel(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my ($arg, $what) = @_;
	my ($cond, $level) = $arg =~ /([<>=!]+)\s*(\d+)/;
	return cmpr($char->{$what}, $cond, $level)
}

# checks for player's jobclass #############################
sub checkClass {
	$cvs->debug("checkClass(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	return 0 unless defined $char->{jobID};
	return lc($_[0]) eq lc($::jobs_lut{$char->{jobID}})?1:0
}

# checks for HP/SP/Weight ##################################
# uses cmpr (Macro::Utils)
sub checkPercent {
	$cvs->debug("checkPercent(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my ($arg, $what) = @_;
	my ($cond, $amount) = $arg =~ /([<>=!]+)\s*(\d+%?)/;
	if ($what =~ /^(hp|sp|weight)$/) {
		return 0 unless (defined $char->{$what} && defined $char->{$what."_max"});
		if ($amount =~ /\d+%$/ && $char->{$what."_max"}) {
			$amount =~ s/%$//;
			return cmpr(($char->{$what} / $char->{$what."_max"} * 100), $cond, $amount)
		} else {
			return cmpr($char->{$what}, $cond, $amount)
		}
	} elsif ($what eq 'cweight') {
		return 0 unless (defined $cart{weight} && defined $cart{weight_max});
		if ($amount =~ /\d+%$/ && $cart{weight_max}) {
			$amount =~ s/%$//;
			return cmpr(($cart{weight} / $cart{weight_max} * 100), $cond, $amount)
		} else {
			return cmpr($cart{weight}, $cond, $amount)
		}
	}
	return 0
}

# checks for status #######################################
sub checkStatus {
	$cvs->debug("checkStatus(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $status = shift;
	if ($status =~ /,/) {
		my @statuses = split(/\s*,\s*/, $status);
		foreach my $s (@statuses) {return 1 if checkStatus($s)}
		return 0
	}
	my $not = 0;
	if ($status =~ /^not /) {$not = 1; $status =~ s/^not +//g}
	if ($status eq 'muted') {
		if ($char->{muted}) {return $not?0:1}
		else {return $not?1:0}
	}
	if ($status eq 'dead') {
		if ($char->{dead}) {return $not?0:1}
		else {return $not?1:0}
	}
	if (!$char->{statuses}) {return $not?1:0}
	foreach (keys %{$char->{statuses}}) {
		if (lc($_) eq lc($status)) {return $not?0:1}
	}
	return $not?1:0
}

# checks for item conditions ##############################
# uses: getInventoryAmount, getCartAmount, getShopAmount,
#       getStorageAmount (Macro::Utils?)
sub checkItem {
	$cvs->debug("checkItem(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my ($where, $check) = @_;
	if ($check =~ /,/) {
		my @checks = split(/\s*,\s*/, $check);
		foreach my $c (@checks) {return 1 if checkItem($where, $c)}
		return 0
	}
	my ($item, $cond, $amount) = getArgs($check);
	my $what;
	if ($where eq 'inv')  {$what = getInventoryAmount($item)}
	if ($where eq 'cart') {$what = getCartAmount($item)}
	if ($where eq 'shop') {
		return 0 unless $shopstarted;
		$what = getShopAmount($item)
	}
	if ($where eq 'stor') {
		return 0 unless $::storage{opened};
		$what = getStorageAmount($item)
	}
	return cmpr($what, $cond, $amount)?1:0
}

# checks for near person ##################################
sub checkPerson {
	$cvs->debug("checkPerson(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my ($who, $dist) = $_[0] =~ /^"(.*)"\s*,?\s*(.*)/;
	return 0 unless defined $who;
	my $r_id = getPlayerID($who, \@playersID);
	return 0 if $r_id < 0;
	return 1 unless $dist;
	my $mypos = calcPosition($char);
	my $pos = calcPosition($::players{$::playersID[$r_id]});
	return distance($mypos, $pos) <= $dist ?1:0
}

# checks arg1 for condition in arg3 #######################
# uses: cmpr (Macro::Utils)
sub checkCond {
	$cvs->debug("checkCond(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $what = shift;
	my ($cond, $amount) = $_[0] =~ /([<>=!]+)\s*(\d+)/;
	return cmpr($what, $cond, $amount)?1:0
}

# checks for equipment ####################################
# equipped <item>, <item2>, ... # equipped item or item2 or ..
# equipped rightHand <item>, rightAccessory <item2>, ... # equipped <item> on righthand etc.
# equipped leftHand none, .. # equipped nothing on lefthand etc.
# see @Item::slots
sub checkEquip {
	$cvs->debug("checkEquip(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $arg = shift;
	if ($arg =~ /,/) {
		my @equip = split(/\s*,\s*/, $arg);
		foreach my $e (@equip) {return 1 if checkEquip($e)}
		return 0
	}

	# check whether or not a slot is given (equipped rightHand whatever)
	foreach my $slot (@slots) {
		if ($arg =~ /^$slot\s+/) {
			$arg =~ s/^$slot\s+//;
			if (my $item = $char->{equipment}{$slot}{name}) {
				return lc($item) eq lc($arg)?1:0
			} else {
				return $arg eq 'none'?1:0
			}
		}
	}
	# check for item (equipped whatever)
	foreach my $item (@{$char->{inventory}}) {
		return 1 if ($item->{equipped} && lc($item->{name}) eq lc($arg))
	}
	return 0
}

# checks for a spell casted on us #########################
# uses: distance, judgeSkillArea (Utils?)
sub checkCast {
	$cvs->debug("checkCast(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my ($cast, $args) = @_;
	my $pos = calcPosition($char);
	return 0 if $args->{sourceID} eq $accountID;
	my $target = (defined $args->{targetID})?$args->{targetID}:0;
	if (($target eq $accountID ||
		($pos->{x} == $args->{x} && $pos->{y} == $args->{y}) ||
		distance($pos, $args) <= judgeSkillArea($args->{skillID})) &&
		existsInList(lc($cast), lc(Skill->new(idn => $args->{skillID})->getName()))) {return 1}
	return 0
}

# checks for public, private, party or guild message ######
# uses calcPosition, distance (Utils?), setVar (Macro::Utils?)
sub checkMsg {
	$cvs->debug("checkMsg(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my ($var, $tmp, $arg) = @_;
	my $msg;
	if ($var eq '.lastpub') {
		($msg, my $distance) = $tmp =~ /^([\/"].*?[\/"]\w*)\s*,?\s*(\d*)/;
		if ($distance ne '') {
			my $mypos = calcPosition($char);
			my $pos = calcPosition($::players{$arg->{pubID}});
			return 0 unless distance($mypos, $pos) <= $distance
		}
	} elsif ($var eq '.lastpm') {
		($msg, my $allowed) = $tmp =~ /^([\/"].*?[\/"]\w*)\s*,?\s*(.*)/;
		my $auth;
		if (!$allowed) {
			$auth = 1
		} else {
			my @tfld = split(/,/, $allowed);
			for (my $i = 0; $i < @tfld; $i++) {
				next unless defined $tfld[$i];
				$tfld[$i] =~ s/^ +//g; $tfld[$i] =~ s/ +$//g;
				if ($arg->{privMsgUser} eq $tfld[$i]) {$auth = 1; last}
			}
		}
		return 0 unless $auth
	} else {
		$msg = $tmp
	}

	$arg->{Msg} =~ s/[\r\n]*$//g;
	if (match($arg->{Msg},$msg)){
		setVar($var, quotemeta $arg->{MsgUser});
		setVar($var."Msg", $arg->{Msg});
		return 1
	}
	return 0
}

# checks for monster, credits to illusionist
sub checkMonster {
	$cvs->debug("checkMonsters(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $monsterList = shift;
	foreach (@monstersID) {
		next unless defined $_;
		if (existsInList($monsterList, $monsters{$_}->{name})) {
			my $pos = calcPosition($monsters{$_});
			my $val = sprintf("%d %d %s", $pos->{x}, $pos->{y}, $field{name});
			setVar(".lastMonster", $monsters{$_}->{name});
			setVar(".lastMonsterPos", $val);
			return 1
		}
	}
	return 0
}

# checks for forbidden monster
# quick hack, maybe combine it with checkMonster later
sub checkNotMonster {
	$cvs->debug("checkNotMonster(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $monsterList = shift;
	foreach (@monstersID) {
		next unless defined $_;
		next if existsInList($monsterList, $monsters{$_}->{name});
		return 1
	}
	return 0
}

# checks for aggressives
sub checkAggressives {
	$cvs->debug("checkAggressives(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $arg = shift;
	my ($cond, $amount) = $arg =~ /([<>=!]+)\s*(\d+)/;
	return cmpr(scalar ai_getAggressives, $cond, $amount)
}

# checks for console message
sub checkConsole {
	$cvs->debug("checkConsole(@_)", $logfac{function_call_auto} | $logfac{automacro_checks}) if defined $cvs;
	my ($msg, $arg) = @_;
	$$arg[4] =~ s/[\r\n]*$//;
	if (match($$arg[4],$msg)){
		$$arg[4] =~ s/\n$//g;
		setVar(".lastLogMsg", $$arg[4]);
		return 1
	}
	return 0
}

sub consoleCheckWrapper {
	return unless defined $conState;
	# skip "macro" and "cvsdebug" domains to avoid loops
	return if $_[1] =~ /^(macro|cvsdebug)$/;
	# skip debug messages unless macro_allowDebug is set
	return if ($_[0] eq 'debug' && !$::config{macro_allowDebug});
	my @args = @_;
	automacroCheck("log", \@args)
}

# checks for map change
sub checkMapChange {
	$cvs->debug("checkMapChange(@_)", $logfac{function_call_auto} | $logfac{automacro_checks});
	my $map = shift;
	return ($map eq '*' || existsInList($map, $field{name}))?1:0
}

# releases a locked automacro ##################
sub releaseAM {
	$cvs->debug("releaseAM(@_)", $logfac{function_call_macro});
	my $am = shift;
	if ($am eq 'all') {
		foreach my $am (keys %automacro) {
			undef $automacro{$am}->{disabled}
		}
		return 1
	}
	if (defined $automacro{$am}) {
		if (defined $automacro{$am}->{disabled}) {
			undef $automacro{$am}->{disabled}
		}
		return 1
	}
	return 0
}

# locks an automacro ##################
sub lockAM {
	$cvs->debug("lockAM(@_)", $logfac{function_call_macro});
	my $am = shift;
	if (defined $automacro{$am}) {
		$automacro{$am}->{disabled} = 1;
		return 1
	}
	return 0
}

# parses automacros and checks conditions #################
sub automacroCheck {
	my ($trigger, $args) = @_;
	return unless $conState == 5 || $trigger =~ /^(charSelectScreen|Network)/;

	# do not run an automacro if there's already a macro running and the running
	# macro is non-interruptible
	return if (defined $queue && !$queue->interruptible);

	CHKAM:
	foreach my $am (sort {
		($automacro{$a}->{priority} or 0) <=> ($automacro{$b}->{priority} or 0)
	} keys %automacro) {
		next CHKAM if $automacro{$am}->{disabled};

		if (defined $automacro{$am}->{call} && !defined $macro{$automacro{$am}->{call}}) {
			error "automacro $am: macro ".$automacro{$am}->{call}." not found.\n";
			$automacro{$am}->{disabled} = 1; return
		}

		if (defined $automacro{$am}->{timeout}) {
			$automacro{$am}->{time} = 0 unless $automacro{$am}->{time};
			my %tmptimer = (timeout => $automacro{$am}->{timeout}, time => $automacro{$am}->{time});
			next CHKAM unless timeOut(\%tmptimer)
		}

		if (defined $automacro{$am}->{hook}) {
			next CHKAM unless $trigger eq $automacro{$am}->{hook};
			# save arguments
			my $s = 0;
			while (my $save = $automacro{$am}->{'save'.$s}) {
				if (defined $args->{$save}) {setVar(".hooksave$s", $args->{$save})}
				else {error "[macro] \$args->{$save} does not exist\n"}
				$s++
			}
		} elsif (defined $automacro{$am}->{console}) {
			if ($trigger eq 'log') {
				next CHKAM unless checkConsole($automacro{$am}->{console}, $args)
			} else {next CHKAM}
		} elsif (defined $automacro{$am}->{spell}) {
			if ($trigger =~ /^(is_casting|packet_skilluse)$/) {
			next CHKAM unless checkCast($automacro{$am}->{spell}, $args)
			} else {next CHKAM}
		} elsif (defined $automacro{$am}->{pm}) {
			if ($trigger eq 'packet_privMsg') {
			next CHKAM unless checkMsg(".lastpm", $automacro{$am}->{pm}, $args)
			} else {next CHKAM}
		} elsif (defined $automacro{$am}->{pubm}) {
			if ($trigger eq 'packet_pubMsg') {
			next CHKAM unless checkMsg(".lastpub", $automacro{$am}->{pubm}, $args)
			} else {next CHKAM}
		} elsif (defined $automacro{$am}->{party}) {
			if ($trigger eq 'packet_partyMsg') {
			next CHKAM unless checkMsg(".lastparty", $automacro{$am}->{party}, $args)
			} else {next CHKAM}
		} elsif (defined $automacro{$am}->{guild}) {
			if ($trigger eq 'packet_guildMsg') {
			next CHKAM unless checkMsg(".lastguild", $automacro{$am}->{guild}, $args)
			} else {next CHKAM}
		} elsif (defined $automacro{$am}->{mapchange}) {
			if ($trigger eq 'packet_mapChange') {
			next CHKAM unless checkMapChange($automacro{$am}->{mapchange})
			} else {next CHKAM}
		}

		next CHKAM if (defined $automacro{$am}->{map}    && $automacro{$am}->{map} ne $field{name});
		next CHKAM if (defined $automacro{$am}->{class}  && !checkClass($automacro{$am}->{class}));
		next CHKAM if (defined $automacro{$am}->{notMonster} && !checkNotMonster($automacro{$am}->{notMonster}));
		foreach my $i (@{$automacro{$am}->{monster}})    {next CHKAM unless checkMonster($i)}
		foreach my $i (@{$automacro{$am}->{aggressives}}){next CHKAM unless checkAggressives($i)}
		foreach my $i (@{$automacro{$am}->{location}})   {next CHKAM unless checkLoc($i)}
		foreach my $i (@{$automacro{$am}->{var}})        {next CHKAM unless checkVar($i)}
		foreach my $i (@{$automacro{$am}->{varvar}})     {next CHKAM unless checkVarVar($i)}
		foreach my $i (@{$automacro{$am}->{base}})       {next CHKAM unless checkLevel($i, "lv")}
		foreach my $i (@{$automacro{$am}->{job}})        {next CHKAM unless checkLevel($i, "lv_job")}
		foreach my $i (@{$automacro{$am}->{hp}})         {next CHKAM unless checkPercent($i, "hp")}
		foreach my $i (@{$automacro{$am}->{sp}})         {next CHKAM unless checkPercent($i, "sp")}
		foreach my $i (@{$automacro{$am}->{spirit}})     {next CHKAM unless checkCond($char->{spirits} or 0, $i)}
		foreach my $i (@{$automacro{$am}->{weight}})     {next CHKAM unless checkPercent($i, "weight")}
		foreach my $i (@{$automacro{$am}->{cartweight}}) {next CHKAM unless checkPercent($i, "cweight")}
		foreach my $i (@{$automacro{$am}->{soldout}})    {next CHKAM unless checkCond(getSoldOut(), $i)}
		foreach my $i (@{$automacro{$am}->{zeny}})       {next CHKAM unless checkCond($char->{zenny}, $i)}
		foreach my $i (@{$automacro{$am}->{player}})     {next CHKAM unless checkPerson($i)}
		foreach my $i (@{$automacro{$am}->{equipped}})   {next CHKAM unless checkEquip($i)}
		foreach my $i (@{$automacro{$am}->{status}})     {next CHKAM unless checkStatus($i)}
		foreach my $i (@{$automacro{$am}->{inventory}})  {next CHKAM unless checkItem("inv", $i)}
		foreach my $i (@{$automacro{$am}->{storage}})    {next CHKAM unless checkItem("stor", $i)}
		foreach my $i (@{$automacro{$am}->{shop}})       {next CHKAM unless checkItem("shop", $i)}
		foreach my $i (@{$automacro{$am}->{cart}})       {next CHKAM unless checkItem("cart", $i)}

		message "[macro] automacro $am triggered.\n", "macro";

		unless (defined $automacro{$am}->{call} || $::config{macro_nowarn}) {
			warning "[macro] automacro $am: call not defined.\n", "macro"
		}

		$automacro{$am}->{time} = time  if $automacro{$am}->{timeout};
		$automacro{$am}->{disabled} = 1 if $automacro{$am}->{'run-once'};

		foreach my $i (@{$automacro{$am}->{set}}) {
			my ($var, $val) = $i =~ /^(.*?)\s+(.*)$/;
			setVar($var, $val)
		}

		if (defined $automacro{$am}->{call}) {
			undef $queue if defined $queue;
			$queue = new Macro::Script($automacro{$am}->{call});
			if (defined $queue) {
				$queue->overrideAI(1) if $automacro{$am}->{overrideAI};
				$queue->interruptible(0) if $automacro{$am}->{exclusive};
				$queue->orphan($automacro{$am}->{orphan}) if defined $automacro{$am}->{orphan};
				$queue->timeout($automacro{$am}->{delay}) if $automacro{$am}->{delay};
				$queue->setMacro_delay($automacro{$am}->{macro_delay}) if $automacro{$am}->{macro_delay};
				setVar(".caller", $am);
				$onHold = 0;
				callMacro
			} else {
				error "unable to create macro queue.\n"
			}
		}

		return # don't execute multiple macros at once
	}
}

1;
