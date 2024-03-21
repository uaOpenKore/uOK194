# Korea (kRO) / eA packet_ver 21
#

package Network::Receive::ServerType8_2;

use strict;
use Network::Receive;
use base qw(Network::Receive);

sub new {
	my ($class) = @_;
	my $self = $class->SUPER::new;
	return $self;
}

# Overrided method.
sub received_characters_blockSize {
	return 108;
}

1;
