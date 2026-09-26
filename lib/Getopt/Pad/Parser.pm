use v5.26;
use Object::Pad;

use Getopt::Long ();
use Getopt::Pad::Error;
use Getopt::Pad::Result::Generator;

class Getopt::Pad::Parser :strict(params) {
	use Feature::Compat::Try;
	use Scalar::Util ();

	our $VERSION = '0.03';

	field $spec :param;
	field $argv :param;

	# The command line is parsed Level by Level first, and the Levels it
	# selects are resolved afterwards, innermost first, since each Result
	# holds the one below it. Every Trigger has fired before anything is
	# resolved, so --help anywhere on the line wins over a missing required
	# option or a broken config file.
	method parse() {
		my @words           = $argv->@*;
		my @steps           = $self->parseCommandLine(\@words);
		my $inheritedValues = $steps[-1]{inheritedValues};
		my $configValues    = $self->inContext($spec->root, sub { $self->loadConfigValues($inheritedValues) });

		my $result;
		foreach my $step (reverse @steps) {
			my $subResult = $result;
			$result = $self->inContext($step->{level}, sub { $self->resolveStep($step, $inheritedValues, $configValues, \@words, $subResult) });
		}
		return $result;
	}

	# User errors raised by $code are attributed to $level, whose help the
	# user sees next to the message.
	method inContext($level, $code) {
		try {
			return $code->();
		}
		catch ($error) {
			$error->attachContext($level) if Scalar::Util::blessed($error) && $error->isa('Getopt::Pad::Error');
			die $error;
		}
	}

	# One step per selected Level: its own command line values, the values
	# of every inherited option given so far, and the command it names.
	method parseCommandLine($words) {
		my @steps;
		my $level           = $spec->root;
		my $inheritedValues = {};
		while (defined $level) {
			my $step = $self->inContext($level, sub { $self->parseLevel($level, $words, $inheritedValues) });
			push @steps, $step;
			$inheritedValues = $step->{inheritedValues};
			$level           = defined $step->{command} ? $level->command($step->{command}) : undef;
		}
		return @steps;
	}

	method parseLevel($level, $words, $inheritedSoFar) {
		my %values = $self->parseOptions($level, $words, $inheritedSoFar);
		$self->fireTriggers($level, \%values);

		# Inherited options leave the Level's own values: they carry on to
		# the next Level and end up with the Level declaring them.
		my %inheritedValues = map { $_->name => delete $values{$_->name} } grep { exists $values{$_->name} } $level->inheritableOptions, $level->inheritedOptions;
		my $command         = $level->hasCommands ? $self->selectCommand($level, $words) : undef;
		return { level => $level, values => \%values, inheritedValues => \%inheritedValues, command => $command };
	}

	# A Trigger sees its option's value after the Value pipeline, so an
	# unsupported --create-completions shell is a user error, not a crash.
	# The values inherited from an outer Level never hold the option of a
	# Trigger: every Trigger ends the parse where it fires.
	method fireTriggers($level, $values) {
		my $helper = $spec->helperFor($level);
		foreach my $option (grep { defined $_->trigger && exists $values->{$_->name} } $level->options) {
			$option->trigger->($helper, $spec, $level, $option->readerValue(commandLine => $values));
		}
		return;
	}

	method selectCommand($level, $words) {
		my $expected = join(', ', $level->commandNames);

		if (!$words->@*) {
			return undef if !$level->commandRequired;
			Getopt::Pad::Error->throw("missing command, expected one of: %s", $expected);
		}

		my $word = shift $words->@*;
		Getopt::Pad::Error->throw("unknown command '%s', expected one of: %s", $word, $expected) if !defined $level->command($word);
		return $word;
	}

	# Getopt::Long stores into a copy of the inherited values given so far,
	# so an inherited option repeated across Levels accumulates exactly as
	# it does when repeated on one.
	method parseOptions($level, $words, $inheritedSoFar) {
		my @glSpecs = map { $_->glSpec } $level->options;
		my @config  = qw(bundling no_ignore_case no_auto_abbrev);
		push @config, $level->hasCommands ? 'require_order' : 'permute';

		my $gl = Getopt::Long::Parser->new(config => \@config);
		my %values = map { $_ => $self->copiedWords($inheritedSoFar->{$_}) } keys $inheritedSoFar->%*;
		my @glWarnings;
		my $ok;
		{
			local $SIG{__WARN__} = sub { push @glWarnings, $_[0] };
			$ok = $gl->getoptionsfromarray($words, \%values, @glSpecs);
		}

		if (!$ok) {
			my $message = join('; ', map { s/\s+$//r } @glWarnings) || 'invalid command line';
			Getopt::Pad::Error->throw('%s', $message);
		}

		return %values;
	}

	method copiedWords($given) {
		return [$given->@*] if ref $given eq 'ARRAY';
		return { $given->%* } if ref $given eq 'HASH';
		return $given;
	}

	method loadConfigValues($inheritedValues) {
		my $configSpec = $spec->config // return {};

		my $configOption = $spec->CONFIG_OPTION;
		return $configSpec->io->autoloadValues($spec->root) if !exists $inheritedValues->{$configOption};
		return $configSpec->io->explicitValues($spec->root, $inheritedValues->{$configOption});
	}

	# The Result of one selected Level. Its inherited options take the words
	# collected on every Level down from it, its options the config values
	# of its own section.
	method resolveStep($step, $inheritedValues, $configValues, $words, $subResult) {
		my $level       = $step->{level};
		my %commandLine = ($step->{values}->%*, map { $_->name => $inheritedValues->{$_->name} } grep { exists $inheritedValues->{$_->name} } $level->inheritableOptions);
		my $config      = $configValues->{$level->path} // {};

		my %readerValues;
		$readerValues{$_->reader} = $_->readerValue(commandLine => \%commandLine, config => $config) foreach $level->declaredOptions;

		my $class  = Getopt::Pad::Result::Generator::generate($level);
		my $helper = $spec->helperFor($level);
		return $class->new(%readerValues, command => $step->{command}, subcommand => $subResult, helper => $helper) if $level->hasCommands;
		return $class->new(%readerValues, $self->consumeArgs($level, $words), helper => $helper);
	}

	method validatedArgValue($arg, $value) {
		my $problem = $arg->type->check($value);
		Getopt::Pad::Error->throw("argument <%s>: %s", $arg->short, $problem) if defined $problem;

		my $coerced = $arg->type->coerce($value);
		$problem = $arg->type->prepare($coerced);
		Getopt::Pad::Error->throw("argument <%s>: %s", $arg->short, $problem) if defined $problem;
		return $coerced;
	}

	method consumeArgs($level, $words) {
		my %readerValues;
		my @args = $level->args;

		foreach my $index (0 .. $#args) {
			my $arg = $args[$index];

			if ($arg->multiple) {
				my @rest = splice($words->@*);
				Getopt::Pad::Error->throw("missing required argument <%s>", $arg->short) if !@rest && $arg->required;
				$readerValues{$arg->reader} = [map { $self->validatedArgValue($arg, $_) } @rest];
				next;
			}

			if (!$words->@*) {
				Getopt::Pad::Error->throw("missing required argument <%s>", $arg->short) if $arg->required;
				next;
			}

			$readerValues{$arg->reader} = $self->validatedArgValue($arg, shift $words->@*);
		}

		Getopt::Pad::Error->throw("unexpected extra argument '%s'", $words->[0]) if $words->@*;

		return %readerValues;
	}
}

1;

__END__

=encoding utf8

=head1 NAME

Getopt::Pad::Parser - the parsing engine

=head1 DESCRIPTION

The parsing engine, in two passes. The first walks the command line: it runs Getopt::Long per level, fires the triggers of auto options seen there and selects the named command. An inherited option is accepted on every level below the one declaring it, and Getopt::Long stores its words on top of those given further out, so it accumulates across levels as it would on one. The second pass loads the config values once (an explicit --config, given on any level, replaces the autoload chain), then resolves the selected levels innermost first: every declared option gets its command line values and the config values of its level's section, inherited options the words collected on all levels, the innermost level consumes the positionals, and each level's generated result object holds the one below it. Throws Getopt::Pad::Error for user mistakes; the triggers throw Getopt::Pad::ExitRequest carrying their output. It never exits itself.

Part of the L<Getopt::Pad> distribution; see its documentation for the user-facing API.

=head1 AUTHOR

davenonymous E<lt>perl@davenonymous.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2026 davenonymous

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
