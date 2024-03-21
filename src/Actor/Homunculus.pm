#########################################################################
#  OpenKore - Homunculus actor object
#  Copyright (c) 2006 OpenKore Team
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#
#  $Revision: 4394 $
#  $Id: Homunculus.pm 4394 2006-07-03 16:16:43Z kaliwanagan $
#
#########################################################################
##
# MODULE DESCRIPTION: Homunculi actor object
#
# All members in %homunculi are of the Actor::Homunculus class.
#
# Actor.pm is the base class for this class.
package Actor::Homunculus;

use strict;

our @ISA = qw(Actor);

sub new {
	my ($class) = @_;
	return $class->SUPER::new('Homunculus');
}

1;
