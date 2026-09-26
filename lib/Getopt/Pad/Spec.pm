use v5.26;
use Object::Pad;

use Getopt::Pad::Spec::Level;
use Getopt::Pad::Spec::Option;
use Getopt::Pad::Spec::Config;
use Getopt::Pad::Config;
use Getopt::Pad::ExitRequest;
use Getopt::Pad::Help;
use Getopt::Pad::Completion;

class Getopt::Pad::Spec :strict(params) {
	use Getopt::Pad::Util qw(specError);

	our $VERSION = '0.03';

	use constant CONFIG_OPTION => 'config';

	# The one table of Auto options: name, placement ('every' Level, the
	# 'root', or the root of a Spec with a 'config' block), option spec, and
	# the Trigger the parser fires when the parsed command line sets it.
	# Every Trigger ends the parse with an ExitRequest carrying its finished
	# output. CONFIG_OPTION carries no Trigger; the parser consumes it for
	# config loading. The config options act on the whole config file, so
	# every Level below the root inherits them.
	my @autoOptions = (
		{
			key       => 'help',
			placement => 'every',
			raw       => sub ($config) { return { hidden => 1, help => 'Print this help text and exit' } },
			trigger   => sub ($helper, $spec, $level, $value) {
				die Getopt::Pad::ExitRequest->new(output => $helper->renderHelp);
			},
		},
		{
			key       => 'version',
			placement => 'root',
			raw       => sub ($config) { return { hidden => 1, help => 'Print the program version and exit' } },
			trigger   => sub ($helper, $spec, $level, $value) {
				die Getopt::Pad::ExitRequest->new(output => $helper->renderVersion . "\n");
			},
		},
		{
			key       => 'create-completions',
			placement => 'root',
			raw       => sub ($config) {
				return {
					type  => 's',
					valid => Getopt::Pad::Completion->SHELLS,
					group => 'Completion',
					help  => 'Print a completion script for this shell to STDOUT and exit',
				};
			},
			trigger   => sub ($helper, $spec, $level, $value) {
				die Getopt::Pad::ExitRequest->new(output => Getopt::Pad::Completion->new(spec => $spec)->renderScript($value));
			},
		},
		{
			key           => CONFIG_OPTION,
			placement     => 'config',
			optionalValue => 1,
			raw           => sub ($config) {
				my $help = sprintf('Load options from this %s config file', $config->formatName);
				$help .= sprintf(' (bare --config loads %s)', $config->defaultPath) if defined $config->defaultPath;
				return { type => 's', group => 'Config', help => $help, inherit => 1 };
			},
		},
		{
			key       => 'create-default-config',
			placement => 'config',
			raw       => sub ($config) {
				return { type => 's', group => 'Config', help => 'Write a config file prefilled with the default values to this path and exit', inherit => 1 };
			},
			trigger   => sub ($helper, $spec, $level, $value) {
				die Getopt::Pad::ExitRequest->new(output => sprintf("Wrote default config to %s\n", $spec->config->io->writeDefaultFile($spec->root, $value)));
			},
		},
	);

	field $raw :param;

	field $root    :reader;
	field $config  :reader;
	field $version :reader;

	ADJUST {
		specError('GetOptions expects key/value pairs') if ref $raw ne 'HASH';

		my %spec = $raw->%*;
		$config  = delete $spec{config};
		$version = delete $spec{version};
		$config  = Getopt::Pad::Spec::Config->new(raw => $config) if defined $config;

		$root = Getopt::Pad::Spec::Level->new(raw => \%spec);
		$self->attachAutoOptions($root, 1);
		$self->passInheritedOptions($root);
		$self->checkCommandsKeyIsFree($root) if defined $config;
	}

	method attachAutoOptions($level, $isRoot) {
		foreach my $entry (@autoOptions) {
			next if $entry->{placement} ne 'every' && !$isRoot;
			next if $entry->{placement} eq 'config' && !defined $config;

			$level->addOption(Getopt::Pad::Spec::Option->new(
				auto    => 1,
				key     => $entry->{key},
				raw     => $entry->{raw}->($config),
				trigger => $entry->{trigger},
				($entry->{optionalValue} ? (optionalValue => 1) : ()),
			));
		}

		$self->attachAutoOptions($level->command($_), 0) foreach $level->commandNames;
	}

	# Every Level below hands on what it received plus its own inheritable
	# options, each paired with the Level declaring it.
	method passInheritedOptions($level, @received) {
		my @passed = (@received, map { [$_, $level] } $level->inheritableOptions);
		foreach my $name ($level->commandNames) {
			my $command = $level->command($name);
			$command->inheritOption($_->@*) foreach @passed;
			$self->passInheritedOptions($command, @passed);
		}
	}

	# A config file holds the command sections of a Level with commands
	# under the COMMANDS_KEY, so no group of such a Level may take its name.
	method checkCommandsKeyIsFree($level) {
		return if !$level->hasCommands;

		my $key = Getopt::Pad::Config->COMMANDS_KEY;
		specError("%sgroup '%s' is reserved for the command sections of config files", $level->where, $key) if grep { $_->group eq $key } $level->declaredOptions;
		$self->checkCommandsKeyIsFree($level->command($_)) foreach $level->commandNames;
	}

	method helperFor($level, %overrides) {
		return Getopt::Pad::Help->new(level => $level, version => $version, %overrides);
	}
}

1;

__END__

=encoding utf8

=head1 NAME

Getopt::Pad::Spec - trusted spec root

=head1 DESCRIPTION

The trusted root of a parsed spec: the root Level plus the config block and version string. Owns the single table of auto options (--help, --version, --create-completions, --config, --create-default-config): each entry names its placement and carries the trigger the parser fires when the option is seen. Once the auto options are attached, it passes every option marked inherit down to all levels below the one declaring it (the two config options are marked so), and with a config block it refuses a group named like the config file's reserved C<commands> key on a level with commands. Every trigger ends the parse by throwing a Getopt::Pad::ExitRequest with its finished output, so nothing outside this table knows what each auto option does. helperFor is the one place Help renderers are constructed.

Part of the L<Getopt::Pad> distribution; see its documentation for the user-facing API.

=head1 AUTHOR

davenonymous E<lt>perl@davenonymous.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2026 davenonymous

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
