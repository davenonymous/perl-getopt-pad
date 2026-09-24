use v5.26;
use Object::Pad;

use Getopt::Pad::Type;
use Getopt::Pad::Error;
use Getopt::Pad::Result;

class Getopt::Pad::Spec::Option :strict(params) {
	use Carp qw(croak);
	use Getopt::Pad::Util qw(camelize specError isValidName);

	our $VERSION = '0.02';

	# The Value sources a parse hands over, in order of precedence, each with
	# the wording of its user errors; the spec default follows them.
	my @valueSources = (
		{ key => 'commandLine', problemFormat => "option '--%s': %s" },
		{ key => 'config',      problemFormat => "config value for '%s': %s" },
	);
	my %isValueSource = map { $_->{key} => 1 } @valueSources;

	field $key           :param;
	field $raw           :param;
	field $auto          :param :reader = 0;
	field $optionalValue :param :reader = 0;
	field $trigger       :param :reader = undef;

	field $name     :reader;
	field @aliases  :reader;
	field $reader   :reader;
	field $type     :reader;
	field $typeName :reader;
	field $required   :reader = 0;
	field $hasDefault :reader = 0;
	field $default    :reader;
	field $valid     :reader;
	field $lazyValid;
	field $group    :reader;
	field $help     :reader = '';
	field $multiple :reader = 0;
	field $hash     :reader = 0;
	field $hidden   :reader = 0;

	ADJUST {
		specError("option key must be a non-empty string") if !defined $key || $key eq '';
		specError("option '%s': spec must be a hash reference", $key) if ref $raw ne 'HASH';
		specError("option '%s': a trigger is only allowed on auto options", $key) if defined $trigger && !$auto;

		($name, @aliases) = split /\|/, $key, -1;
		foreach my $candidate ($name, @aliases) {
			specError("option '%s': invalid name '%s'", $key, $candidate // '') if !isValidName($candidate);
		}
		$reader = camelize($name);
		specError("option '%s': reader '%s' collides with a built-in result method", $name, $reader) if !$auto && Getopt::Pad::Result->reservesReader($reader);

		my %spec = $raw->%*;
		($type, $typeName) = Getopt::Pad::Type::takeFromSpec(\%spec, 'flag', sprintf("option '%s'", $name));

		$required = delete $spec{required} ? 1 : 0;
		if (exists $spec{default}) {
			$hasDefault = 1;
			$default    = delete $spec{default};
		}
		$valid     = delete $spec{valid};
		$lazyValid = delete $spec{lazyValid};
		$group    = delete $spec{group} // 'Options';
		$help     = delete $spec{help} // '';
		$multiple = delete $spec{multiple} ? 1 : 0;
		$hash     = delete $spec{hash} ? 1 : 0;
		$hidden   = delete $spec{hidden} ? 1 : 0;

		specError("option '%s': unknown key(s): %s", $name, join(', ', sort keys %spec)) if %spec;
		specError("option '%s': required and default are mutually exclusive", $name) if $required && $hasDefault;
		specError("option '%s': multiple requires a value-taking type, not '%s'", $name, $typeName) if $multiple && !$type->takesValue;
		specError("option '%s': hash requires a value-taking type, not '%s'", $name, $typeName) if $hash && !$type->takesValue;
		specError("option '%s': multiple and hash are mutually exclusive", $name) if $multiple && $hash;
		specError("option '%s': valid must be an array or code reference", $name) if defined $valid && ref $valid ne 'ARRAY' && ref $valid ne 'CODE';
		specError("option '%s': lazyValid must be a code reference", $name) if defined $lazyValid && ref $lazyValid ne 'CODE';

		$default = $self->checkedDefault($default) if $hasDefault;
	}

	# The spec default in the option's shape, every value checked and
	# coerced: a list for a multiple option, a mapping for a hash option.
	method checkedDefault($value) {
		if ($multiple) {
			specError("option '%s': default for a multiple option must be an array reference", $name) if ref $value ne 'ARRAY';
			return [map { $self->checkedSingleDefault($_) } $value->@*];
		}
		if ($hash) {
			specError("option '%s': default for a hash option must be a hash reference", $name) if ref $value ne 'HASH';
			specError("option '%s': default value: empty key", $name) if exists $value->{''};
			return { map { $_ => $self->checkedSingleDefault($value->{$_}, sprintf("key '%s': ", $_)) } keys $value->%* };
		}
		return $self->checkedSingleDefault($value);
	}

	method checkedSingleDefault($value, $where = '') {
		my ($problem, $coerced) = $self->checkValue($value);
		specError("option '%s': default value: %s%s", $name, $where, $problem) if defined $problem;
		return $coerced;
	}

	# What the reader gets when no value source set the option and the spec
	# has no default: an empty list or mapping, or undef.
	method emptyValue() {
		return [] if $multiple;
		return {} if $hash;
		return undef;
	}

	# Each parse gets its own copy of a list or mapping default.
	method copiedDefault() {
		return [$default->@*] if ref $default eq 'ARRAY';
		return { $default->%* } if ref $default eq 'HASH';
		return $default;
	}

	# The values the valid constraint allows right now: the static list, or
	# what the valid coderef produces when asked. Empty without a constraint.
	method validValues() {
		return () if !defined $valid;
		return $valid->@* if ref $valid eq 'ARRAY';

		my $values = $valid->();
		specError("option '%s': the valid coderef must return an array reference", $name) if ref $values ne 'ARRAY';
		return $values->@*;
	}

	# Check $value's shape, then the type, the valid list and the lazyValid
	# predicate. Returns the problem description (undef when the value is
	# acceptable) and the coerced value; the caller decides how to report
	# the problem.
	method checkValue($value) {
		return ('expected a single value, not a list or mapping', $value) if ref $value eq 'ARRAY' || ref $value eq 'HASH';

		my $problem = $type->check($value);
		return ($problem, $value) if defined $problem;

		$value = $type->coerce($value);
		if (defined $valid) {
			my @allowed = $self->validValues;
			return (sprintf("'%s' is not one of: %s", $value, join(', ', @allowed)), $value) if !grep { $_ eq $value } @allowed;
		}
		return (sprintf("'%s' is not a valid value", $value), $value) if defined $lazyValid && !$lazyValid->($value);
		return (undef, $value);
	}

	# The Reader value for one parse. %sources maps each Value source to the
	# raw values it gave, keyed by Primary name; a name missing from a map
	# means that source did not set the option.
	method readerValue(%sources) {
		my @unknown = grep { !$isValueSource{$_} } sort keys %sources;
		croak(sprintf("Getopt::Pad: unknown value source(s): %s", join(', ', @unknown))) if @unknown;

		foreach my $source (@valueSources) {
			my $given = $sources{$source->{key}} // {};
			next if !exists $given->{$name};
			return $self->validatedValue($given->{$name}, $source->{problemFormat});
		}

		return $self->copiedDefault if $hasDefault;
		Getopt::Pad::Error->throw("missing required option '--%s'", $name) if $required;
		return $self->emptyValue;
	}

	method validatedValue($value, $problemFormat) {
		return $self->validatedHashValue($value, $problemFormat) if $hash;
		return $self->validatedSingleValue($value, $problemFormat) if !$multiple;

		# A config file may give a lone value for a multiple option.
		my @values = ref $value eq 'ARRAY' ? $value->@* : ($value);
		return [map { $self->validatedSingleValue($_, $problemFormat) } @values];
	}

	# The command line gives key=value pairs already split into a mapping; a
	# config file may give any shape. Every value passes the single-value
	# pipeline, the problem names its key.
	method validatedHashValue($value, $problemFormat) {
		Getopt::Pad::Error->throw($problemFormat, $name, 'expected a mapping of keys to values') if ref $value ne 'HASH';

		my %validated;
		foreach my $key (sort keys $value->%*) {
			Getopt::Pad::Error->throw($problemFormat, $name, 'empty key') if $key eq '';
			$validated{$key} = $self->validatedSingleValue($value->{$key}, $problemFormat, sprintf("key '%s': ", $key));
		}
		return \%validated;
	}

	method validatedSingleValue($value, $problemFormat, $where = '') {
		Getopt::Pad::Error->throw($problemFormat, $name, $where . 'no value given') if !defined $value;

		my ($problem, $coerced) = $self->checkValue($value);
		Getopt::Pad::Error->throw($problemFormat, $name, $where . $problem) if defined $problem;
		return $coerced;
	}

	method glSpec() {
		return $type->glSpec(join('|', $name, @aliases), optionalValue => $optionalValue, multiple => $multiple, hash => $hash);
	}

	method negatable() {
		return $type->negatable;
	}
}

1;

__END__

=encoding utf8

=head1 NAME

Getopt::Pad::Spec::Option - one option spec

=head1 DESCRIPTION

A single validated option spec: primary name, aliases, type instance, reader name, and the required/default/valid/lazyValid/group/help/multiple/hash settings. A default is validated and coerced at construction time, in the option's shape: a list for a multiple option, a mapping for a hash option. readerValue resolves the reader value for one parse: it takes the first value source that set the option (command line, then config file) or else the spec default, runs every value through checkValue, the single check/coerce pipeline (a hash option's problems name their key), and throws a Getopt::Pad::Error worded for that source, or for a missing required option. An option no source set and without a default reads as an empty list (multiple), an empty mapping (hash) or undef. validValues lists what the valid constraint allows: the static list, or the array reference the valid coderef returns when called; shell completion asks it for candidates. lazyValid is a predicate run after the valid check. Auto options may carry a trigger, the reaction the parser runs when the parsed command line sets the option.

Part of the L<Getopt::Pad> distribution; see its documentation for the user-facing API.

=head1 AUTHOR

davenonymous E<lt>perl@davenonymous.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2026 davenonymous

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
