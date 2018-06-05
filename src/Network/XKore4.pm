#########################################################################
#  OpenKore - Networking subsystem
#  This module contains functions for sending packets to the server.
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#
#  $Revision: 7069 $
#  $Id: Network.pm 7069 2010-01-16 02:23:00Z klabmouse $
#
#########################################################################
##
# MODULE DESCRIPTION: Connection handling
#
# The Network module handles connections to the Ragnarok Online server.
# This module only handles connection issues, and nothing else. It doesn't do
# anything with the actual data. Network data handling is performed by
# the @MODULE(Network::Receive) and Network::Receive::ServerTypeX classes.
#
# The submodule @MODULE(Network::Send) contains functions for sending all
# kinds of messages to the RO server.
#
# Please also read <a href="http://wiki.openkore.com/index.php/Network_subsystem">the
# network subsystem overview.</a>
#
# This implementation establishes a direct connection to the RO server.
# Note that there are alternative implementations for this interface: @MODULE(Network::XKore),
# @MODULE(Network::XKore2) and @MODULE(Network::XKoreProxy)

package Network::XKore4;

use strict;
use Modules 'register';
use Exporter;
use base qw(Exporter);
use Time::HiRes qw(time);
use IO::Socket::INET;
use utf8;
use Scalar::Util;
use File::Spec;

use Globals;
use Log qw(message warning error debug);
use Misc qw(chatLog);
use Network;
use Network::Send ();
use Plugins;
use Settings;
use Interface;
use Utils qw(dataWaiting timeOut);
use Utils::Exceptions;
use Translation qw(T TF);

my $clientBuffer;
my %flushTimer;
my $loginpacket;

##
# Network::DirectConnection->new([wrapper])
# wrapper: If this object is to be wrapped by another object which is interface-compatible
#          with the Network::DirectConnection class, then specify the wrapper object here. The message
#          sender will use this wrapper to send socket data. Internally, the reference to the wrapper
#          will be stored as a weak reference.
#
# Create a new Network::DirectConnection object. The connection is not yet established.
sub new {
	my ($class, $wrapper) = @_;
	my %self;

	my $ip = $config{XKore_listenIp} || '0.0.0.0';
	my $port = $config{XKore_listenPort} || 6901;
	my $self = bless {}, $class;

	$self->{tokenizer} = new Network::MessageTokenizer($self->getRecvPackets());
	$self->{publicIP} = $config{XKore_publicIp} || undef;
	$self->{client_state} = 0;
	$self->{nextIp} = undef;
	$self->{nextPort} = undef;
	$self->{charServerIp} = undef;
	$self->{charServerPort} = undef;
	$self->{gotError} = 0;
	$self->{waitingClient} = 1;
	{
		no encoding 'utf8';
		$self->{packetPending} = '';
		$clientBuffer = '';
	}

	message T("X-Kore mode intialized.\n"), "startup";

	$self{remote_socket} = new IO::Socket::INET;
	if ($wrapper) {
		$self{wrapper} = $wrapper;
		Scalar::Util::weaken($self{wrapper});
	}

	return bless \%self, $class;
}

##
# int $net->version()
#
# Returns the implementation number this object.
sub version {
	return 0;
}

sub DESTROY {
	my $self = shift;
	
	$self->serverDisconnect();
}


######################
## Server Functions ##
######################

##
# boolean $net->serverAliveServer()
#
# Check whether the connection to the server is alive.
sub serverAlive {
	return $_[0]->{remote_socket} && $_[0]->{remote_socket}->connected();
}

##
# String $net->serverPeerHost()
#
# If the connection to the server is alive, returns the host name of the server.
# Otherwise, returns undef.
sub serverPeerHost {
	return $_[0]->{remote_socket}->peerhost if ($_[0]->serverAlive);
	return undef;
}

##
# int $net->serverPeerPort()
#
# If the connection to the server is alive, returns the port number of the server.
# Otherwise, returns undef.
sub serverPeerPort {
	return $_[0]->{remote_socket}->peerport if ($_[0]->serverAlive);
	return undef;
}

##
# $net->serverConnect(String host, int port)
# host: the host name/IP of the RO server to connect to.
# port: the port number of the RO server to connect to.
#
# Establish a connection to a Ragnarok Online server.
#
# This function is used internally by $net->checkConnection() and should not be used directly.
sub serverConnect {
	my $self = shift;
	my $host = shift;
	my $port = shift;
	my $return = 0;

	Plugins::callHook('Network::connectTo', {
		socket => \$self->{remote_socket},
		return => \$return,
		host => $host,
		port => $port
	});
	return if ($return);

	message TF("Connecting (%s:%s)... ", $host, $port), "connection";
	$self->{remote_socket} = new IO::Socket::INET(
			LocalAddr	=> $config{bindIp} || undef,
			PeerAddr	=> $host,
			PeerPort	=> $port,
			Proto		=> 'tcp',
			Timeout		=> 4);
	($self->{remote_socket} && inet_aton($self->{remote_socket}->peerhost()) eq inet_aton($host)) ?
		message T("connected\n"), "connection" :
		error(TF("couldn't connect: %s (error code %d)\n", "$!", int($!)), "connection");
	if ($self->getState() != Network::NOT_CONNECTED) {
		$incomingMessages->nextMessageMightBeAccountID();
	}
}

##
# void $net->serverSend(Bytes data)
#
# If the connection to the server is alive, send data to the server.
# Otherwise, this method does nothing.
sub serverSend {
	my $self = shift;
	my $msg = shift;
	if ($self->serverAlive) {
		if (Plugins::hasHook("Network::serverSend/pre")) {
			Plugins::callHook("Network::serverSend/pre", { msg => \$msg });
		}
		if (defined $msg) {
			$self->{remote_socket}->send($msg);
			if (Plugins::hasHook("Network::serverSend")) {
				Plugins::callHook("Network::serverSend", { msg => $msg });
			}
		}
	}
}

##
# Bytes $net->serverRecv()
#
# Receive data from the RO server.
sub serverRecv {
	my $self = shift;
	my $msg;
	
	return undef unless (dataWaiting(\$self->{remote_socket}));
	
	$self->{remote_socket}->recv($msg, 1024 * 32);
	if (Plugins::hasHook("Network::serverRecv")) {
		Plugins::callHook("Network::serverRecv", { msg => \$msg });
	}
	if (!defined($msg) || length($msg) == 0) {
		# Connection from server closed.
		close($self->{remote_socket});
		return undef;
	}
	return $msg;
}

##
# Bytes $net->serverAddress()
#
# Return the server's raw address.
sub serverAddress {
	my ($self) = @_;
	return $self->{remote_socket}->sockaddr();
}

##
# $net->serverDisconnect()
#
# Disconnect from the current Ragnarok Online server.
#
# This function is used internally by $net->checkConnection() and should not be used directly.
sub serverDisconnect {
	my $self = shift;
	
	if ($self->serverAlive) {
		if ($incomingMessages && length(my $incoming = $incomingMessages->getBuffer)) {
				warning TF("Incoming data left in the buffer:\n");
				Misc::visualDump($incoming);
				
				if (defined(my $rplen = $incomingMessages->{rpackets}{my $switch = Network::MessageTokenizer::getMessageID($incoming)})) {
					my $inlen = do { no encoding 'utf8'; use bytes; length $incoming };
					if (($rplen->{length} > $inlen) || ($rplen->{minLength} > $inlen)) { # check for minLength too, if defined
						warning TF("Only %d bytes in the buffer, when %s's packet length is supposed to be %d (wrong recvpackets?)\n", $inlen, $switch, $rplen);
					}
				}
		}

		$messageSender->sendQuit() if ($self->getState() == Network::IN_GAME);

		message TF("Disconnecting (%s:%s)...", $self->{remote_socket}->peerhost(), 
			$self->{remote_socket}->peerport()), "connection";
		close($self->{remote_socket});
		
		if ($self->serverAlive()) {
			error T("couldn't disconnect\n"), "connection";
			Plugins::callHook("serverDisconnect/fail");
		} else {
			message T("disconnected\n"), "connection";
			Plugins::callHook("serverDisconnect/success");
		}
	}
}

sub getState {
	return $conState;
}

sub setState {
	my ($self, $state) = @_;
	$conState = $state;
	Plugins::callHook('Network::stateChanged');
}


######################
## Client Functions ##
######################

######################
## Client Functions ##
######################

sub clientAlive {
	my $self = shift;
	return $self->proxyAlive();
}

sub proxyAlive {
	my $self = shift;
	return $self->{proxy} && $self->{proxy}->connected;
}

sub clientPeerHost {
	my $self = shift;
	return $self->{proxy}->peerhost if ($self->proxyAlive);
	return undef;
}

sub clientPeerPort {
	my $self = shift;
	return $self->{proxy}->peerport if ($self->proxyAlive);
	return undef;
}

sub clientSend {
	my $self = shift;
	my $msg = shift;
	my $dontMod = shift;

	return unless ($self->proxyAlive);

	# queue message instead of sending directly
	$clientBuffer .= $msg;
}

sub clientFlush {
	my $self = shift;

	return unless (length($clientBuffer));

	$self->{proxy}->send($clientBuffer);
	debug "Client network buffer flushed out\n";
	$clientBuffer = '';
}

sub clientRecv {
	my ($self, $msg) = @_;

	return undef unless ($self->proxyAlive && dataWaiting(\$self->{proxy}));

	$self->{proxy}->recv($msg, 1024 * 32);
	
	return unless ($self->proxyAlive);
	
	my $switch = uc(unpack("H2", substr($msg, 1, 1))) . uc(unpack("H2", substr($msg, 0, 1)));
	if(length($msg) < 30) { return undef; }
	
	if($switch eq "0064") {
		$messageSender->sendToServer($msg);
	}

	return undef;
}

#######################
## Utility Functions ##
#######################

#######################################
#######################################
# Check Connection
#######################################
#######################################

##
# $net->checkConnection()
#
# Handles any connection issues. Based on the current situation, this function may
# re-connect to the RO server, disconnect, do nothing, etc.
#
# This function is meant to be run in the Kore main loop.
sub checkConnection {
	my $self = shift;
	
	return if ($Settings::no_connect);

	if ($self->getState() == Network::NOT_CONNECTED && (!$self->{remote_socket} || !$self->{remote_socket}->connected) && timeOut($timeout_ex{'master'}) && !$conState_tries) {
		# Check connection to the client
		$self->checkProxy();

		# Check server connection
		$self->checkServer();
	} elsif ($self->getState() == Network::CONNECTED_TO_MASTER_SERVER) {
		if(!$self->serverAlive() && ($config{'server'} ne "" || $masterServer->{charServer_ip}) && !$conState_tries) {
			if ($config{pauseCharServer}) {
				message "Pausing for $config{pauseCharServer} second(s)...\n", "system";
				sleep $config{pauseCharServer};
			}
			my $master = $masterServer;
			message T("Connecting to Character Server...\n"), "connection";
			$conState_tries++;
			$captcha_state = 0;

			if ($master->{charServer_ip}) {
				$self->serverConnect($master->{charServer_ip}, $master->{charServer_port});
			} elsif ($servers[$config{'server'}]) {
				message TF("Selected server: %s\n", $servers[$config{server}]->{name}), 'connection';
				$self->serverConnect($servers[$config{'server'}]{'ip'}, $servers[$config{'server'}]{'port'});
			} else {
				error TF("Invalid server specified, server %s does not exist...\n", $config{server}), "connection";

				my @serverList;
				foreach my $server (@servers) {
					push @serverList, $server->{name};
				}
				my $ret = $interface->showMenu(
						T("Please select your login server."),
						\@serverList,
						title => T("Select Login Server"));
				if ($ret == -1) {
					quit();
				} else {
					main::configModify('server', $ret, 1);
					undef $conState_tries;
				}
				return;
			}

			# call plugin's hook to determine if we can continue the connection
			if ($self->serverAlive) {
				Plugins::callHook("Network::serverConnect/char");
				$reconnectCount = 0;
				return if ($conState == 1.5);
			}
			# TODO: the connect code needs a major rewrite =/
			unless($masterServer->{captcha}) {
				$messageSender->sendGameLogin($accountID, $sessionID, $sessionID2, $accountSex);
				$timeout{'gamelogin'}{'time'} = time;
			}
		} elsif($self->serverAlive() && $masterServer->{captcha}) {
			if ($captcha_state == 0) { # send initiate once, then wait for servers captcha_answer packet
				$messageSender->sendCaptchaInitiate();
				$captcha_state = -1;
			} elsif ($captcha_state == 1) { # captcha answer was correct, sent sendGameLogin once, then wait for servers 
				$messageSender->sendGameLogin($accountID, $sessionID, $sessionID2, $accountSex);
				$timeout{'gamelogin'}{'time'} = time;
				$captcha_state = -1;
			} else {
				return;
			}
		} elsif (timeOut($timeout{'gamelogin'}) && ($config{'server'} ne "" || $masterServer->{'charServer_ip'})) {
			error TF("Timeout on Character Server, reconnecting. Wait %s seconds...\n", $timeout{'reconnect'}{'timeout'}), "connection";
			$timeout_ex{'master'}{'time'} = time;
			$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
			$self->serverDisconnect;
			undef $conState_tries;
			$self->setState(Network::NOT_CONNECTED);
		}
	} elsif ($self->getState() == Network::CONNECTED_TO_LOGIN_SERVER) {
		if(!$self->serverAlive() && $config{'char'} ne "" && !$conState_tries) {
			message T("Connecting to Character Select Server...\n"), "connection";
			$conState_tries++;
			$self->serverConnect($servers[$config{'server'}]{'ip'}, $servers[$config{'server'}]{'port'});

			# call plugin's hook to determine if we can continue the connection
			if ($self->serverAlive) {
				Plugins::callHook("Network::serverConnect/charselect");
				return if ($conState == 1.5);
			}
					
			$messageSender->sendCharLogin($config{'char'});
			$timeout{'charlogin'}{'time'} = time;

		} elsif (timeOut($timeout{'charlogin'}) && $config{'char'} ne "") {
			error T("Timeout on Character Select Server, reconnecting...\n"), "connection";
			$timeout_ex{'master'}{'time'} = time;
			$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
			$self->serverDisconnect;
			$self->setState(Network::NOT_CONNECTED);
			undef $conState_tries;
		}
	} elsif ($self->getState() == Network::CONNECTED_TO_CHAR_SERVER) {
		if(!$self->serverAlive() && !$conState_tries) {
			if ($config{pauseMapServer}) {
				message "Pausing for $config{pauseMapServer} second(s)...\n", "system";
				sleep($config{pauseMapServer});
			}
			message T("Connecting to Map Server...\n"), "connection";
			$conState_tries++;
			main::initConnectVars();
			my $master = $masterServer;
			my ($ip, $port);
			if ($master->{private}) {
				$ip = $config{forceMapIP} || $master->{ip};
				$port = $map_port;
			} else {
				$ip = $master->{mapServer_ip} || $config{forceMapIP} || $map_ip;
				$port = $master->{mapServer_port} || $map_port;
			}
			$self->serverConnect($ip, $port);

			# call plugin's hook to determine if we can continue the connection
			if ($self->serverAlive) {
				Plugins::callHook("Network::serverConnect/mapserver");
				return if ($conState == 1.5);
			}

			$messageSender->sendMapLogin($accountID, $charID, $sessionID, $accountSex2);
			$timeout_ex{master}{time} = time;
			$timeout_ex{master}{timeout} = $timeout{reconnect}{timeout};
			$timeout{maplogin}{time} = time;

		} elsif (timeOut($timeout{maplogin})) {
			message T("Timeout on Map Server, connecting to Account Server...\n"), "connection";
			$timeout_ex{master}{timeout} = $timeout{reconnect}{timeout};
			$self->serverDisconnect;
			$self->setState(Network::NOT_CONNECTED);
			undef $conState_tries;
		}
	} elsif ($self->getState() == Network::IN_GAME) {
		if(!$self->serverAlive()) {
			Plugins::callHook('disconnected');
			if ($config{dcOnDisconnect}) {
				error T("Auto disconnecting on Disconnect!\n");
				chatLog("k", T("*** You disconnected, auto disconnect! ***\n"));
				$quit = 1;
			} else {
				message TF("Disconnected from Map Server, connecting to Account Server in %s seconds...\n", $timeout{reconnect}{timeout}), "connection";
				$timeout_ex{master}{time} = time;
				$timeout_ex{master}{timeout} = $timeout{reconnect}{timeout};
				$self->setState(Network::NOT_CONNECTED);
				undef $conState_tries;
			}

		} elsif (timeOut($timeout{play})) {
			error T("Timeout on Map Server, "), "connection";
			Plugins::callHook('disconnected');
			if ($config{dcOnDisconnect}) {
				error T("Auto disconnecting on Disconnect!\n");
				chatLog("k", T("*** You disconnected, auto disconnect! ***\n"));
				$quit = 1;
			} else {
				error TF("connecting to Account Server in %s seconds...\n", $timeout{reconnect}{timeout}), "connection";
				$timeout_ex{master}{time} = time;
				$timeout_ex{master}{timeout} = $timeout{reconnect}{timeout};
				$self->serverDisconnect;
				$self->setState(Network::NOT_CONNECTED);
				undef $conState_tries;
			}
		}
	}
}

sub checkProxy {
	my $self = shift;

	if (defined $self->{proxy_listen}) {
		# Listening for a client
		if (dataWaiting($self->{proxy_listen})) {
			# Client is connecting...
			$self->{proxy} = $self->{proxy_listen}->accept;

			# Tell 'em about the new client
			my $host = $self->clientPeerHost;
			my $port = $self->clientPeerPort;
			debug "XKore Proxy: RO Client connected ($host:$port).\n", "connection";

			# Stop listening and clear errors.
			close($self->{proxy_listen});
			undef $self->{proxy_listen};
			$self->{gotError} = 0;
		}
		#return;

	} elsif (!$self->proxyAlive) {
		# Client disconnected... (or never existed)
		if ($self->serverAlive()) {
			message T("Client disconnected\n"), "connection";
			$self->setState(Network::NOT_CONNECTED) if ($self->getState() == Network::IN_GAME);
			$self->{waitingClient} = 1;
			$self->serverDisconnect();
		}

		close $self->{proxy} if $self->{proxy};
		$self->{waitClientDC} = undef;
		debug "Removing pending packet from queue\n" if (defined $self->{packetPending});
		$self->{packetPending} = '';

		# FIXME: there's a racing condition here. If the RO client tries to connect
		# to the listening port before we've set it up (this happens if sleepTime is
		# sufficiently high), then the client will freeze.

		# (Re)start listening...
		my $ip = $config{XKore_listenIp} || '127.0.0.1';
		my $port = $config{XKore_listenPort} || 6901;
		$self->{proxy_listen} = new IO::Socket::INET(
			LocalAddr	=> $ip,
			LocalPort	=> $port,
			Listen		=> 5,
			Proto		=> 'tcp',
			ReuseAddr   => 1);
		die "Unable to start the X-Kore proxy ($ip:$port): $@\n" .
			"Make sure no other servers are running on port $port." unless $self->{proxy_listen};

		# setup master server if necessary
		getMainServer();

		message TF("Waiting Ragnarok Client to connect on (%s:%s)\n", ($ip eq '127.0.0.1' ? 'localhost' : $ip), $port), "startup" if ($self->{waitingClient} == 1);
		$self->{waitingClient} = 0;
		return;
	}
}

sub proxyAlive {
	my $self = shift;
	return $self->{proxy} && $self->{proxy}->connected;
}


sub checkServer {
	my $self = shift;

	# Do nothing until the client has (re)connected to us
	return if (!$self->proxyAlive() || $self->{waitClientDC});

	# Connect to the next server for proxying the packets
	if (!$self->serverAlive()) {

		# Setup the next server to connect.
		if (!$self->{nextIp} || !$self->{nextPort}) {
			# if no next server was defined by received packets, setup a primary server.
			my $master = $masterServer = $masterServers{$config{'master'}};

			$self->{nextIp} = $master->{ip};
			$self->{nextPort} = $master->{port};
			message TF("Proxying to [%s]\n", $config{master}), "connection" unless ($self->{gotError});
			eval {
				$clientPacketHandler = Network::ClientReceive->new;
				$packetParser = Network::Receive->create($self, $masterServer->{serverType});
				$messageSender = Network::Send->create($self, $masterServer->{serverType});
			};
			if (my $e = caught('Exception::Class::Base')) {
				$interface->errorDialog($e->message());
				$quit = 1;
				return;
			}
		}

		$self->serverConnect($self->{nextIp}, $self->{nextPort}) unless ($self->{gotError});
		if (!$self->serverAlive()) {
			$self->{charServerIp} = undef;
			$self->{charServerPort} = undef;
			close($self->{proxy});
			error T("Invalid server specified or server does not exist...\n"), "connection" if (!$self->{gotError});
			$self->{gotError} = 1;
		}

		# clean Next Server uppon connection
		$self->{nextIp} = undef;
		$self->{nextPort} = undef;
	}
}

sub getRecvPackets {
	return \%rpackets;
}

sub getMainServer {
	if ($config{'master'} eq "" || $config{'master'} =~ /^\d+$/ || !exists $masterServers{$config{'master'}}) {
		my @servers = sort { lc($a) cmp lc($b) } keys(%masterServers);
		my $choice = $interface->showMenu(
			T("Please choose a master server to connect to."),
			\@servers,
			title => T("Master servers"));
		if ($choice == -1) {
			exit;
		} else {
			configModify('master', $servers[$choice], 1);
		}
	}
}

return 1;
