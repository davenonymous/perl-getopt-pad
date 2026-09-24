# Getopt::Pad

The domain language of Getopt::Pad, an Object::Pad based options processor.
One context for the whole distribution; full behavioral design in DESIGN.md.

## Language

### Declaration side

**Spec**:
The trusted object tree parsed from the raw `GetOptions` arguments before any
command line is looked at. Everything after spec construction operates on
validated objects, never on the raw hashes.
_Avoid_: schema, definition, config (reserved for config files)

**Level**:
One node of the Spec: a set of Options plus either Args or Commands. The
top-level call and every Command each form one Level.
_Avoid_: scope, layer

**Option**:
A named `--switch` declared under `options`, possibly taking a value.
_Avoid_: flag, switch, parameter

**Arg**:
A positional value declared under `args`, consumed in declaration order after
Options are parsed.
_Avoid_: positional, operand, argument (when meaning an Option's value)

**Command**:
A named nested Level under `commands`, selected by the first bare word on the
command line. Never coexists with Args on the same Level.
_Avoid_: subcommand (that is the Result reader returning the nested Result),
verb, action

**Primary name**:
The first name in a pipe-separated Option key (`'owner|o'` -> `owner`). It
alone defines the Reader name and the help entry.
_Avoid_: canonical name, main name

**Alias**:
Any name after the first in a pipe-separated Option key. Parsed, never shown
as the Option's identity.
_Avoid_: short name, abbreviation

**Group**:
The help section an Option is rendered under; Options without one fall into a
default Group.
_Avoid_: category, section

**Auto option**:
An Option added by Getopt::Pad itself rather than declared in the spec.
`--help` is attached to every Level; `--version` and `--create-completions`
only to the root; `--config` and `--create-default-config` only to the root
and only when the Spec has a config block. Auto options have no Reader; a
Trigger receives its Option's value after the Value pipeline, `--config` is
consumed by config loading.
_Avoid_: builtin option, implicit option

**Declared option**:
An Option the spec declares under `options`, as opposed to an Auto option.
Only Declared options get Readers and take part in the value pipeline.
_Avoid_: user option, real option

**Trigger**:
The reaction an Auto option carries: it runs when the parsed command line sets
that Option and ends the parse with one control-flow exception, an
ExitRequest carrying its finished output (`--help`, `--version`,
`--create-completions`, `--create-default-config`). GetOptions prints that
output and exits without knowing which Trigger fired. `--config` carries no
Trigger; it is consumed by config loading instead.
_Avoid_: handler, callback, action

**Config block**:
The validated `config` section of the Spec: format, paths, defaultPath and
autoload. Pure declaration data - every config file read and write goes
through the Config I/O it hands out.
_Avoid_: config spec, config object

**Config I/O**:
The single owner of the grouped config file structure (group, then option
name, then value): loads an explicit path or the autoload chain, enforces
group membership, and writes the default config file.
_Avoid_: config loader, config manager

### Result side

**Value source**:
Where a Declared option's value comes from: the command line, a config file,
or the spec default, in that order of precedence. Required is checked only
when no Value source supplies a value.
_Avoid_: origin, input, layer

**Value pipeline**:
The checks a raw value from a Value source passes inside its Option before it
becomes a Reader value: shape (a single value, a list for `multiple`, a
mapping of `key=value` pairs for `hash`), then per value the Type's check and
coercion, the Valid list and the lazyValid predicate. Spec defaults pass it
once, when the Spec is built. An Option no Value source set and without a
default reads as an empty list or mapping in those shapes, else undef.
_Avoid_: validation chain, value processing

**Valid list**:
The values an Option's `valid` key allows: a static arrayref, or a coderef
that returns the current arrayref whenever it is asked - at validation and
on every Completion request. `lazyValid` is the predicate form for
constraints that cannot be listed; it never completes.
_Avoid_: valid coderef (when meaning the predicate), whitelist, choices

**Completion request**:
One tab press relayed by a generated completion script: the program is run
again with `GETOPT_PAD_COMPLETE` and `GETOPT_PAD_COMPLETE_INDEX` set and the
typed words as arguments, and GetOptions answers with a directive line
(`files`, `dirs` or `none`) followed by one candidate per line instead of
parsing. Only Getopt::Pad::Completion knows that protocol and the shell
scripts speaking it.
_Avoid_: completion callback, tab handler

**Result**:
The object a successful parse returns: a runtime-generated Object::Pad class
per Level (cached by its Reader set, so parses and Levels with identical
Readers share one class) with one Reader per Declared option and Arg, plus
`help`, `version`, `command` and `subcommand` methods.
_Avoid_: options object, opts, values

**Reader**:
The camelCase accessor on a Result derived from a kebab-case Primary name or
Arg short name (`work-dir` -> `workDir`).
_Avoid_: getter, accessor, field (reserved for Object::Pad internals)

**Helper**:
The renderer behind `--help`, `--version` and error output for one Level.
Only the Spec constructs Helpers; the command path a Helper prints is derived
from its Level, never passed alongside it.
_Avoid_: help object, usage printer

### Extension points

**Type**:
An Object::Pad class under `Getopt::Pad::Type::` that maps a spec type name
to a Getopt::Long suffix, validates or coerces values, and contributes help
annotations. The Type module builds a Type from an Option or Arg spec
itself, taking the type name and the keys the Type declares (`SPEC_KEYS`)
out of the spec; Options and Args only name their default type.
_Avoid_: constraint, validator, kind

**glSuffix**:
The Getopt::Long suffix a Type contributes (`''`, `'!'`, `'+'`, `'=s'`) -
the only place Getopt::Long spelling enters a Type. The Type base class
derives `takesValue` and `negatable` from it and assembles the full option
specification in `glSpec`; nothing outside the Type seam inspects it.
_Avoid_: sigil, gl spec (that is the assembled option specification)

**Format**:
An Object::Pad class under `Getopt::Pad::Config::Format::` that translates
one config file syntax (yaml, json) between text and data. It never touches
files or encodings: Config I/O reads and writes every config file as UTF-8
and hands the Format decoded text.
_Avoid_: loader, backend

**Registry**:
The lookup table where Types and Formats register their names; the only place
a spec type or config format name is resolved.
_Avoid_: factory, plugin manager
