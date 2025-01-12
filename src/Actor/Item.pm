#########################################################################
#  OpenKore - Item object
#  Copyright (c) 2005, 2006 OpenKore Team
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#
#  $Revision: 5221 $
#  $Id: Item.pm 5221 2006-12-20 23:06:09Z vcl_kore $
#
#########################################################################
##
# MODULE DESCRIPTION: Inventory item object
#
# All members in $char->{inventory} are of the Actor::Item class.

package Actor::Item;

use strict;
use Carp::Assert;
use Scalar::Util;
use Time::HiRes qw(time);

use Globals;
use Actor;
use base qw(Actor);
use Utils;
use Log qw(message error warning debug);
use Network::Send ();
use AI;

use overload '""' => \&_toString;
use overload '==' => \&_isis;
use overload '!=' => \&_not_is;
use overload 'eq' => \&_eq;
use overload 'ne' => \&_ne;

sub _toString {
	return $_[0]->nameString();
}

sub _isis {
	return Scalar::Util::refaddr($_[0]) == Scalar::Util::refaddr($_[1]);
}

sub _not_is {
	return !&_isis;
}

sub _eq {
	return UNIVERSAL::isa($_[0], 'Actor::Item') && UNIVERSAL::isa($_[1], 'Actor::Item')
		&& $_[0]->{nameID} == $_[1]->{nameID};
}

sub _ne {
	return !&_eq;
}


our @slots = qw(
	topHead midHead lowHead
	leftHand rightHand
	robe armor shoes
	leftAccessory rightAccessory
	arrow
);


##############################
### CATEGORY: Constructor
##############################

##
# Actor::Item Actor::Item->new()
#
# Creates a new Actor::Item object.
sub new {
	my $class = $_[0];
	my $self = $class->SUPER::new('Item');
	$self->{name} = 'Uninitialized Item';
	$self->{index} = 0;
	$self->{amount} = 0;
	$self->{type} = 0;
	$self->{equipped} = 0;
	$self->{identified} = 0;
	$self->{nameID} = 0;
	$self->{invIndex} = 0;
	return $self;
}


##############################
### CATEGORY: Class Methods
##############################

##
# Actor::Item::get(name, skipIndex, notEquipped)
# item: can be either an object itself, an ID or a name.
# skipIndex: tells this function to not select a certain item (used for getting another item with the same name).
# notEquipped: do not select unequipped items.
# Returns: an Actor::Item object, or undef if not found.
#
# Find an item in the inventory, based on the search criteria specified by the parameters.
#
# See also: Actor::Item::getMultiple()
sub get {
	my ($name, $skipIndex, $notEquipped) = @_;

	return undef if (!defined $name);
	return $name if UNIVERSAL::isa($name, 'Actor::Item');

	# user supplied an inventory index
	if ($name =~ /^\d+$/) {
		my $item = $char->{inventory}[$name];
		return undef unless $item;
		assert(UNIVERSAL::isa($item, 'Actor::Item')) if DEBUG;
		return $item;

	# user supplied an item name
	} else {
		my $index;
		if ($notEquipped) {
			$index = findIndexString_lc_not_equip($char->{inventory}, 'name', $name, $skipIndex);
		} else {
			$index = findIndexString_lc($char->{inventory}, 'name', $name, $skipIndex);
		}
		return undef if !defined($index);
		my $item = $char->{inventory}[$index];
		return undef unless $item;

		assert(UNIVERSAL::isa($item, 'Actor::Item')) if DEBUG;
		return $item;
	}
}

##
# Actor::Item::getMultiple(searchPattern)
# searchString: a search pattern.
# Returns: an array of Actor::Item objects.
#
# Select one or more items in the inventory. $searchPattern has the following syntax:
# <pre>index1,index2,...,indexN</pre>
# You can also use '-' to indicate a range, like:
# <pre>1-5,7,9</pre>
sub getMultiple {
	my @temp = split /,+/, $_[0];
	my @items;

	foreach my $index (@temp) {
		if ($index =~ /(\d+)-(\d+)/) {
			for ($1..$2) {
				my $item = Actor::Item::get($_);
				push(@items, $item) if ($item);
			}
		} else {
			my $item = Actor::Item::get($index);
			push @items, $item if ($item);
		}
	}
	return @items;
}

##
# Actor::Item::bulkEquip(list)
# list: a hash containing slot => item, where slot is "leftHand" or "rightHand", and item is an item identifier as recognized by Actor::Item::get().
#
# Equip many items in one batch.
#
# Example:
# %list = (leftHand => 'Katar', rightHand => 10);
# Actor::Item::bulkEquip(\%list);
sub bulkEquip {
	my $list = shift;

	return unless $list && %{$list};

	my ($item, $rightHand, $rightAccessory);
	foreach (keys %{$list}) {
		if (!exists $equipSlot_rlut{$_}) {
			debug "Wrong Itemslot specified: $_\n",'Actor::Item';
		}

		my $skipIndex;
		$skipIndex = $rightHand if ($_ eq 'leftHand');
		$skipIndex = $rightAccessory if ($_ eq 'leftAccessory');
		$item = Actor::Item::get($list->{$_}, $skipIndex, 1);

		next if !$item;

		$item->equipInSlot($_);

		$rightHand = $item->{invIndex} if $_ eq 'rightHand';
		$rightAccessory = $item->{invIndex} if $_ eq 'rightAccessory';
	}
}

##
# Actor::Item::scanConfigAndEquip(prefix)
#
# prefix: is used to scan for slots
#
# e.g.:
# <pre>
# $prefix = equipAuto_1
# will equip
# equipAuto_1_leftHand Sword
# </pre>
sub scanConfigAndEquip {
	my $prefix = shift;
	my %eq_list;

	debug "Scanning config and equipping: $prefix\n";

	foreach my $slot (%equipSlot_lut) {
		if ($config{"${prefix}_$slot"}){
			$eq_list{$slot} = $config{"${prefix}_$slot"};
		}
	}
	bulkEquip(\%eq_list) if (%eq_list);
}

##
# Actor::Item::scanConfigAndCheck(prefix)
# prefix: is used to scan for slots.
# Returns: whether there is a item that needs to be equipped.
#
# Similiar to Actor::Item::scanConfigAndEquip() but only checks if a Actor::Item needs to be equipped.
sub scanConfigAndCheck {
	my $prefix = $_[0];
	return 0 unless $prefix;

	my $count = 0;
	foreach my $slot (values %equipSlot_lut) {
		if (exists $config{"${prefix}_$slot"}){
			my $item = get($config{"${prefix}_$slot"});
			if ($item && !($char->{equipment}{$slot} && $char->{equipment}{$slot}{name} eq $item->{name})) {
				$count++;
			}
		}
	}
	return $count;
}


##
# Actor::Item::queueEquip(count)
# count: how many items need to be equipped.
#
# Queues equip sequence.
sub queueEquip {
	my $count = shift;
	return unless $count;
	$ai_v{temp}{waitForEquip} += $count;
	AI::queue('equip') unless AI::action eq 'equip';
	$timeout{ai_equip_giveup}{time} = time;
}

##########
# Maybe this Method is not needed.
sub UnEquipByType {
	my $type = shift;

	for (my $i = 0; $i < @{$char->{'inventory'}}; $i++) {
		next if (!%{$char->{'inventory'}[$i]});

		if ($char->{'inventory'}[$i]{'equipped'} & $type) {
			$char->{'inventory'}[$i]->unequip();
			return $i;
		}
	}

	return undef;
}


################################
### CATEGORY: Public Members
################################

##
# String $ActorItem->{name}
# Invariant: defined(value)
#
# The name for this item.

##
# int $ActorItem->{index}
# Invariant: value >= 0
#
# The index of this item in the inventory, as stored on the RO server. It is usually
# used when sending item-related commands (such as 'use this item' or 'drop this item')
# to the RO server.
# This index does not necessarily equals the inventory index, as stored by OpenKore.
#
# Ssee also: $ActorItem->{invIndex}

##
# int $ActorItem->{amount}
# Invariant: value >= 0
#
# The amount of this item in the inventory.

##
# int $ActorItem->{type}
# Invariant: value >= 0
#
# The item type (usable, unusable, armor, etc.), as defined by itemtypes.txt.

##
# boolean $ActorItem->{equipped}
#
# Whether this item is currently equipped.

##
# boolean $ActorItem->{identified}
#
# Whether this item is identified.

##
# int $ActorItem->{nameID}
# Invariant: value >= 0
#
# The ID of this item. This ID is unique for each item class.
# Use this in combination with %items_lut to retrieve the item name.

##
# int $ActorItem->{invIndex}
#
# The index of this item in the inventory data structure, as stored by OpenKore.
# This index does not necessarily correspond with the index as stored by the RO server.
#
# See also: $ActorItem->{index}

##
# Bytes $ActorItem->{takenBy}
#
# The ID of the actor who has taken this item. This field is set when an
# actor picks up an item.


################################
### CATEGORY: Public Methods
################################

##
# String $ActorItem->nameString()
# Returns: the item name, in the form of "My Item [number of slots]".
sub nameString {
	my $self = shift;
	return "$self->{name} ($self->{invIndex})";
}

##
# $ActorItem->equippedInSlot(slot)
# slot: slot to check
# Returns: wheter item is equipped in $slot
sub equippedInSlot {
	my ($self, $slot) = @_;
	return ($self->{equipped} & $equipSlot_rlut{$slot});
}

#sub equippable {
#	my $self = shift;
#}

##
# void $ActorItem->equip()
#
# Will simply equip the item. If you want more control, use $item->equipInSlot()
sub equip {
	my $self = shift;
	return 1 if $self->{equipped};
	$messageSender->sendEquip($self->{index}, $self->{type_equip});
	queueEquip(1);
	return 0;
}

##
# void $ActorItem->unequip()
#
# Unequips the item.
sub unequip {
	my $self = shift;
	return 1 unless $self->{equipped};
	$messageSender->sendUnequip($self->{index});
	return 0;
}

##
# void $ActorItem->use([Bytes target])
# target: ID of the target, if not set then $accountID will be used.
#
# Uses this item on yourself or on a target.
sub use {
	my $self = shift;
	my $target = shift;
	return 0 unless $self->{type} <= 2;
	if (!$target || $target == $accountID) {
		$messageSender->sendItemUse($self->{index}, $accountID);
	}
	else {
		$messageSender->sendItemUse($self->{index}, $target);
	}
	return 1;
}

##
# void $ActorItem->equipInSlot(slot dontqueue)
# slot: where item should be equipped.
#
# Equips item in $slot.
sub equipInSlot {
	my ($self,$slot) = @_;
	return 1 unless defined $equipSlot_rlut{$slot};
	return 1 if ($char->{equipment}{$slot} # return if Item is already equipped
				&& $char->{equipment}{$slot}{name} eq $self->{name});
	#UnEquipByType($equipSlot_rlut{$slot});

	# this is not needed, it screws up clips (can be equipped in multiple (two) slots)
	#if ($equipSlot_rlut{$slot} ^ $self->{type_equip}) {
		#checks whether item uses multiple slots
	#	$messageSender->sendEquip($self->{index}, $self->{type_equip});
	#}
	#else {
		$messageSender->sendEquip($self->{index}, $equipSlot_rlut{$slot});
	#}
	queueEquip(1);
	return 0;
}

1;
