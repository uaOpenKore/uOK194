# pRO Thor as of December 6 2006
package Network::Receive::ServerType15;

use strict;
use Network::Receive::ServerType14;
use base qw(Network::Receive::ServerType14);

sub new {
	my ($class) = @_;
	my $self = $class->SUPER::new;
	return $self;
}

1;
