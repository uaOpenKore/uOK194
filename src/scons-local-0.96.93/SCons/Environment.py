"""SCons.Environment

Base class for construction Environments.  These are
the primary objects used to communicate dependency and
construction information to the build engine.

Keyword arguments supplied when the construction Environment
is created are construction variables used to initialize the
Environment 
"""

#
# Copyright (c) 2001, 2002, 2003, 2004 The SCons Foundation
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
# KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
# WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/Environment.py 0.96.93.D001 2006/11/06 08:31:54 knight"


import copy
import os
import os.path
import popen2
import string
from UserDict import UserDict

import SCons.Action
import SCons.Builder
from SCons.Debug import logInstanceCreation
import SCons.Defaults
import SCons.Errors
import SCons.Node
import SCons.Node.Alias
import SCons.Node.FS
import SCons.Node.Python
import SCons.Platform
import SCons.SConsign
import SCons.Sig
import SCons.Sig.MD5
import SCons.Sig.TimeStamp
import SCons.Subst
import SCons.Tool
import SCons.Util
import SCons.Warnings

class _Null:
    pass

_null = _Null

CleanTargets = {}
CalculatorArgs = {}

# Pull UserError into the global name space for the benefit of
# Environment().SourceSignatures(), which has some import statements
# which seem to mess up its ability to reference SCons directly.
UserError = SCons.Errors.UserError

def installFunc(target, source, env):
    """Install a source file into a target using the function specified
    as the INSTALL construction variable."""
    try:
        install = env['INSTALL']
    except KeyError:
        raise SCons.Errors.UserError('Missing INSTALL construction variable.')
    return install(target[0].path, source[0].path, env)

def installString(target, source, env):
    s = env.get('INSTALLSTR', '')
    if callable(s):
        return s(target[0].path, source[0].path, env)
    else:
        return env.subst_target_source(s, 0, target, source)

installAction = SCons.Action.Action(installFunc, installString)

InstallBuilder = SCons.Builder.Builder(action=installAction,
                                       name='InstallBuilder')

def alias_builder(env, target, source):
    pass

AliasBuilder = SCons.Builder.Builder(action = alias_builder,
                                     target_factory = SCons.Node.Alias.default_ans.Alias,
                                     source_factory = SCons.Node.FS.Entry,
                                     multi = 1,
                                     is_explicit = None,
                                     name='AliasBuilder')

def our_deepcopy(x):
   """deepcopy lists and dictionaries, and just copy the reference
   for everything else."""
   if SCons.Util.is_Dict(x):
       copy = {}
       for key in x.keys():
           copy[key] = our_deepcopy(x[key])
   elif SCons.Util.is_List(x):
       copy = map(our_deepcopy, x)
       try:
           copy = x.__class__(copy)
       except AttributeError:
           pass
   else:
       copy = x
   return copy

def apply_tools(env, tools, toolpath):
    # Store the toolpath in the Environment.
    if toolpath is not None:
        env['toolpath'] = toolpath

    if not tools:
        return
    # Filter out null tools from the list.
    for tool in filter(None, tools):
        if SCons.Util.is_List(tool) or type(tool)==type(()):
            toolname = tool[0]
            toolargs = tool[1] # should be a dict of kw args
            tool = apply(env.Tool, [toolname], toolargs)
        else:
            env.Tool(tool)

# These names are controlled by SCons; users should never set or override
# them.  This warning can optionally be turned off, but scons will still
# ignore the illegal variable names even if it's off.
reserved_construction_var_names = \
    ['TARGET', 'TARGETS', 'SOURCE', 'SOURCES']

def copy_non_reserved_keywords(dict):
    result = our_deepcopy(dict)
    for k in result.keys():
        if k in reserved_construction_var_names:
            SCons.Warnings.warn(SCons.Warnings.ReservedVariableWarning,
                                "Ignoring attempt to set reserved variable `%s'" % k)
            del result[k]
    return result

def _set_reserved(env, key, value):
    msg = "Ignoring attempt to set reserved variable `%s'" % key
    SCons.Warnings.warn(SCons.Warnings.ReservedVariableWarning, msg)

def _set_BUILDERS(env, key, value):
    try:
        bd = env._dict[key]
        for k in bd.keys():
            del bd[k]
    except KeyError:
        env._dict[key] = BuilderDict(kwbd, env)
    env._dict[key].update(value)

def _set_SCANNERS(env, key, value):
    env._dict[key] = value
    env.scanner_map_delete()

class BuilderWrapper:
    """Wrapper class that associates an environment with a Builder at
    instantiation."""
    def __init__(self, env, builder):
        self.env = env
        self.builder = builder

    def __call__(self, target=None, source=_null, *args, **kw):
        if source is _null:
            source = target
            target = None
        if not target is None and not SCons.Util.is_List(target):
            target = [target]
        if not source is None and not SCons.Util.is_List(source):
            source = [source]
        return apply(self.builder, (self.env, target, source) + args, kw)

    # This allows a Builder to be executed directly
    # through the Environment to which it's attached.
    # In practice, we shouldn't need this, because
    # builders actually get executed through a Node.
    # But we do have a unit test for this, and can't
    # yet rule out that it would be useful in the
    # future, so leave it for now.
    def execute(self, **kw):
        kw['env'] = self.env
        apply(self.builder.execute, (), kw)

class BuilderDict(UserDict):
    """This is a dictionary-like class used by an Environment to hold
    the Builders.  We need to do this because every time someone changes
    the Builders in the Environment's BUILDERS dictionary, we must
    update the Environment's attributes."""
    def __init__(self, dict, env):
        # Set self.env before calling the superclass initialization,
        # because it will end up calling our other methods, which will
        # need to point the values in this dictionary to self.env.
        self.env = env
        UserDict.__init__(self, dict)

    def __setitem__(self, item, val):
        UserDict.__setitem__(self, item, val)
        try:
            self.setenvattr(item, val)
        except AttributeError:
            # Have to catch this because sometimes __setitem__ gets
            # called out of __init__, when we don't have an env
            # attribute yet, nor do we want one!
            pass

    def setenvattr(self, item, val):
        """Set the corresponding environment attribute for this Builder.

        If the value is already a BuilderWrapper, we pull the builder
        out of it and make another one, so that making a copy of an
        existing BuilderDict is guaranteed separate wrappers for each
        Builder + Environment pair."""
        try:
            builder = val.builder
        except AttributeError:
            builder = val
        setattr(self.env, item, BuilderWrapper(self.env, builder))

    def __delitem__(self, item):
        UserDict.__delitem__(self, item)
        delattr(self.env, item)

    def update(self, dict):
        for i, v in dict.items():
            self.__setitem__(i, v)

class SubstitutionEnvironment:
    """Base class for different flavors of construction environments.

    This class contains a minimal set of methods that handle contruction
    variable expansion and conversion of strings to Nodes, which may or
    may not be actually useful as a stand-alone class.  Which methods
    ended up in this class is pretty arbitrary right now.  They're
    basically the ones which we've empirically determined are common to
    the different construction environment subclasses, and most of the
    others that use or touch the underlying dictionary of construction
    variables.

    Eventually, this class should contain all the methods that we
    determine are necessary for a "minimal" interface to the build engine.
    A full "native Python" SCons environment has gotten pretty heavyweight
    with all of the methods and Tools and construction variables we've
    jammed in there, so it would be nice to have a lighter weight
    alternative for interfaces that don't need all of the bells and
    whistles.  (At some point, we'll also probably rename this class
    "Base," since that more reflects what we want this class to become,
    but because we've released comments that tell people to subclass
    Environment.Base to create their own flavors of construction
    environment, we'll save that for a future refactoring when this
    class actually becomes useful.)
    """

    if SCons.Memoize.use_memoizer:
        __metaclass__ = SCons.Memoize.Memoized_Metaclass

    def __init__(self, **kw):
        """Initialization of an underlying SubstitutionEnvironment class.
        """
        if __debug__: logInstanceCreation(self, 'Environment.SubstitutionEnvironment')
        self.fs = SCons.Node.FS.default_fs or SCons.Node.FS.FS()
        self.ans = SCons.Node.Alias.default_ans
        self.lookup_list = SCons.Node.arg2nodes_lookups
        self._dict = kw.copy()
        self._init_special()

    def _init_special(self):
        """Initial the dispatch table for special handling of
        special construction variables."""
        self._special = {}
        for key in reserved_construction_var_names:
            self._special[key] = _set_reserved
        self._special['BUILDERS'] = _set_BUILDERS
        self._special['SCANNERS'] = _set_SCANNERS

    def __cmp__(self, other):
        return cmp(self._dict, other._dict)

    def __delitem__(self, key):
        "__cache_reset__"
        del self._dict[key]

    def __getitem__(self, key):
        return self._dict[key]

    def __setitem__(self, key, value):
        "__cache_reset__"
        special = self._special.get(key)
        if special:
            special(self, key, value)
        else:
            if not SCons.Util.is_valid_construction_var(key):
                raise SCons.Errors.UserError, "Illegal construction variable `%s'" % key
            self._dict[key] = value

    def get(self, key, default=None):
        "Emulates the get() method of dictionaries."""
        return self._dict.get(key, default)

    def has_key(self, key):
        return self._dict.has_key(key)

    def items(self):
        return self._dict.items()

    def arg2nodes(self, args, node_factory=_null, lookup_list=_null):
        if node_factory is _null:
            node_factory = self.fs.File
        if lookup_list is _null:
            lookup_list = self.lookup_list

        if not args:
            return []

        if SCons.Util.is_List(args):
            args = SCons.Util.flatten(args)
        else:
            args = [args]

        nodes = []
        for v in args:
            if SCons.Util.is_String(v):
                n = None
                for l in lookup_list:
                    n = l(v)
                    if not n is None:
                        break
                if not n is None:
                    if SCons.Util.is_String(n):
                        n = self.subst(n, raw=1)
                        if node_factory:
                            n = node_factory(n)
                    if SCons.Util.is_List(n):
                        nodes.extend(n)
                    else:
                        nodes.append(n)
                elif node_factory:
                    v = node_factory(self.subst(v, raw=1))
                    if SCons.Util.is_List(v):
                        nodes.extend(v)
                    else:
                        nodes.append(v)
            else:
                nodes.append(v)
    
        return nodes

    def gvars(self):
        return self._dict

    def lvars(self):
        return {}

    def subst(self, string, raw=0, target=None, source=None, conv=None):
        """Recursively interpolates construction variables from the
        Environment into the specified string, returning the expanded
        result.  Construction variables are specified by a $ prefix
        in the string and begin with an initial underscore or
        alphabetic character followed by any number of underscores
        or alphanumeric characters.  The construction variable names
        may be surrounded by curly braces to separate the name from
        trailing characters.
        """
        gvars = self.gvars()
        lvars = self.lvars()
        lvars['__env__'] = self
        return SCons.Subst.scons_subst(string, self, raw, target, source, gvars, lvars, conv)

    def subst_kw(self, kw, raw=0, target=None, source=None):
        nkw = {}
        for k, v in kw.items():
            k = self.subst(k, raw, target, source)
            if SCons.Util.is_String(v):
                v = self.subst(v, raw, target, source)
            nkw[k] = v
        return nkw

    def subst_list(self, string, raw=0, target=None, source=None, conv=None):
        """Calls through to SCons.Subst.scons_subst_list().  See
        the documentation for that function."""
        gvars = self.gvars()
        lvars = self.lvars()
        lvars['__env__'] = self
        return SCons.Subst.scons_subst_list(string, self, raw, target, source, gvars, lvars, conv)

    def subst_path(self, path, target=None, source=None):
        """Substitute a path list, turning EntryProxies into Nodes
        and leaving Nodes (and other objects) as-is."""

        if not SCons.Util.is_List(path):
            path = [path]

        def s(obj):
            """This is the "string conversion" routine that we have our
            substitutions use to return Nodes, not strings.  This relies
            on the fact that an EntryProxy object has a get() method that
            returns the underlying Node that it wraps, which is a bit of
            architectural dependence that we might need to break or modify
            in the future in response to additional requirements."""
            try:
                get = obj.get
            except AttributeError:
                pass
            else:
                obj = get()
            return obj

        r = []
        for p in path:
            if SCons.Util.is_String(p):
                p = self.subst(p, target=target, source=source, conv=s)
                if SCons.Util.is_List(p):
                    if len(p) == 1:
                        p = p[0]
                    else:
                        # We have an object plus a string, or multiple
                        # objects that we need to smush together.  No choice
                        # but to make them into a string.
                        p = string.join(map(SCons.Util.to_String, p), '')
            else:
                p = s(p)
            r.append(p)
        return r

    subst_target_source = subst

    def backtick(self, command):
        try:
            popen2.Popen3
        except AttributeError:
            (tochild, fromchild, childerr) = os.popen3(self.subst(command))
            tochild.close()
            err = childerr.read()
            out = fromchild.read()
            fromchild.close()
            status = childerr.close()
        else:
            p = popen2.Popen3(command, 1)
            p.tochild.close()
            out = p.fromchild.read()
            err = p.childerr.read()
            status = p.wait()
        if err:
            import sys
            sys.stderr.write(err)
        if status:
            try:
                if os.WIFEXITED(status):
                    status = os.WEXITSTATUS(status)
            except AttributeError:
                pass
            raise OSError("'%s' exited %s" % (command, status))
        return out

    def Override(self, overrides):
        """
        Produce a modified environment whose variables are overriden by
        the overrides dictionaries.  "overrides" is a dictionary that
        will override the variables of this environment.

        This function is much more efficient than Clone() or creating
        a new Environment because it doesn't copy the construction
        environment dictionary, it just wraps the underlying construction
        environment, and doesn't even create a wrapper object if there
        are no overrides.
        """
        if overrides:
            o = copy_non_reserved_keywords(overrides)
            overrides = {}
            for key, value in o.items():
                overrides[key] = SCons.Subst.scons_subst_once(value, self, key)
        if overrides:
            env = OverrideEnvironment(self, overrides)
            return env
        else:
            return self

    def ParseFlags(self, *flags):
        """
        Parse the set of flags and return a dict with the flags placed
        in the appropriate entry.  The flags are treated as a typical
        set of command-line flags for a GNU-like toolchain and used to
        populate the entries in the dict immediately below.  If one of
        the flag strings begins with a bang (exclamation mark), it is
        assumed to be a command and the rest of the string is executed;
        the result of that evaluation is then added to the dict.
        """
        dict = {
            'ASFLAGS'       : [],
            'CCFLAGS'       : [],
            'CPPDEFINES'    : [],
            'CPPFLAGS'      : [],
            'CPPPATH'       : [],
            'FRAMEWORKPATH' : [],
            'FRAMEWORKS'    : [],
            'LIBPATH'       : [],
            'LIBS'          : [],
            'LINKFLAGS'     : [],
            'RPATH'         : [],
        }

        # The use of the "me" parameter to provide our own name for
        # recursion is an egregious hack to support Python 2.1 and before.
        def do_parse(arg, me, self = self, dict = dict):
            # if arg is a sequence, recurse with each element
            if not arg:
                return

            if not SCons.Util.is_String(arg):
                for t in arg: me(t, me)
                return

            # if arg is a command, execute it
            if arg[0] == '!':
                arg = self.backtick(arg[1:])

            # utility function to deal with -D option
            def append_define(name, dict = dict):
                t = string.split(name, '=')
                if len(t) == 1:
                    dict['CPPDEFINES'].append(name)
                else:
                    dict['CPPDEFINES'].append([t[0], string.join(t[1:], '=')])

            # Loop through the flags and add them to the appropriate option.
            # This tries to strike a balance between checking for all possible
            # flags and keeping the logic to a finite size, so it doesn't
            # check for some that don't occur often.  It particular, if the
            # flag is not known to occur in a config script and there's a way
            # of passing the flag to the right place (by wrapping it in a -W
            # flag, for example) we don't check for it.  Note that most
            # preprocessor options are not handled, since unhandled options
            # are placed in CCFLAGS, so unless the preprocessor is invoked
            # separately, these flags will still get to the preprocessor.
            # Other options not currently handled:
            #  -iqoutedir      (preprocessor search path)
            #  -u symbol       (linker undefined symbol)
            #  -s              (linker strip files)
            #  -static*        (linker static binding)
            #  -shared*        (linker dynamic binding)
            #  -symbolic       (linker global binding)
            #  -R dir          (deprecated linker rpath)
            # IBM compilers may also accept -qframeworkdir=foo
    
            params = string.split(arg)
            append_next_arg_to = None   # for multi-word args
            for arg in params:
                if append_next_arg_to:
                   if append_next_arg_to == 'CPPDEFINES':
                       append_define(arg)
                   elif append_next_arg_to == '-include':
                       t = ('-include', self.fs.File(arg))
                       dict['CCFLAGS'].append(t)
                   elif append_next_arg_to == '-isysroot':
                       t = ('-isysroot', arg)
                       dict['CCFLAGS'].append(t)
                       dict['LINKFLAGS'].append(t)
                   elif append_next_arg_to == '-arch':
                       t = ('-arch', arg)
                       dict['CCFLAGS'].append(t)
                       dict['LINKFLAGS'].append(t)
                   else:
                       dict[append_next_arg_to].append(arg)
                   append_next_arg_to = None
                elif not arg[0] in ['-', '+']:
                    dict['LIBS'].append(self.fs.File(arg))
                elif arg[:2] == '-L':
                    if arg[2:]:
                        dict['LIBPATH'].append(arg[2:])
                    else:
                        append_next_arg_to = 'LIBPATH'
                elif arg[:2] == '-l':
                    if arg[2:]:
                        dict['LIBS'].append(arg[2:])
                    else:
                        append_next_arg_to = 'LIBS'
                elif arg[:2] == '-I':
                    if arg[2:]:
                        dict['CPPPATH'].append(arg[2:])
                    else:
                        append_next_arg_to = 'CPPPATH'
                elif arg[:4] == '-Wa,':
                    dict['ASFLAGS'].append(arg[4:])
                    dict['CCFLAGS'].append(arg)
                elif arg[:4] == '-Wl,':
                    if arg[:11] == '-Wl,-rpath=':
                        dict['RPATH'].append(arg[11:])
                    elif arg[:7] == '-Wl,-R,':
                        dict['RPATH'].append(arg[7:])
                    elif arg[:6] == '-Wl,-R':
                        dict['RPATH'].append(arg[6:])
                    else:
                        dict['LINKFLAGS'].append(arg)
                elif arg[:4] == '-Wp,':
                    dict['CPPFLAGS'].append(arg)
                elif arg[:2] == '-D':
                    if arg[2:]:
                        append_define(arg[2:])
                    else:
                        appencd_next_arg_to = 'CPPDEFINES'
                elif arg == '-framework':
                    append_next_arg_to = 'FRAMEWORKS'
                elif arg[:14] == '-frameworkdir=':
                    dict['FRAMEWORKPATH'].append(arg[14:])
                elif arg[:2] == '-F':
                    if arg[2:]:
                        dict['FRAMEWORKPATH'].append(arg[2:])
                    else:
                        append_next_arg_to = 'FRAMEWORKPATH'
                elif arg == '-mno-cygwin':
                    dict['CCFLAGS'].append(arg)
                    dict['LINKFLAGS'].append(arg)
                elif arg == '-mwindows':
                    dict['LINKFLAGS'].append(arg)
                elif arg == '-pthread':
                    dict['CCFLAGS'].append(arg)
                    dict['LINKFLAGS'].append(arg)
                elif arg[0] == '+':
                    dict['CCFLAGS'].append(arg)
                    dict['LINKFLAGS'].append(arg)
                elif arg in ['-include', '-isysroot', '-arch']:
                    append_next_arg_to = arg
                else:
                    dict['CCFLAGS'].append(arg)
    
        for arg in flags:
            do_parse(arg, do_parse)
        return dict

    def MergeFlags(self, args, unique=1):
        """
        Merge the dict in args into the construction variables.  If args
        is not a dict, it is converted into a dict using ParseFlags.
        If unique is not set, the flags are appended rather than merged.
        """

        if not SCons.Util.is_Dict(args):
            args = self.ParseFlags(args)
        if not unique:
            apply(self.Append, (), args)
            return self
        for key, value in args.items():
            if value == '':
                continue
            try:
                orig = self[key]
            except KeyError:
                orig = value
            else:
                if len(orig) == 0: orig = []
                elif not SCons.Util.is_List(orig): orig = [orig]
                orig = orig + value
            t = []
            if key[-4:] == 'PATH':
                ### keep left-most occurence
                for v in orig:
                    if v not in t:
                        t.append(v)
            else:
                ### keep right-most occurence
                orig.reverse()
                for v in orig:
                    if v not in t:
                        t.insert(0, v)
            self[key] = t
        return self

class Base(SubstitutionEnvironment):
    """Base class for "real" construction Environments.  These are the
    primary objects used to communicate dependency and construction
    information to the build engine.

    Keyword arguments supplied when the construction Environment
    is created are construction variables used to initialize the
    Environment.
    """

    if SCons.Memoize.use_memoizer:
        __metaclass__ = SCons.Memoize.Memoized_Metaclass

    #######################################################################
    # This is THE class for interacting with the SCons build engine,
    # and it contains a lot of stuff, so we're going to try to keep this
    # a little organized by grouping the methods.
    #######################################################################

    #######################################################################
    # Methods that make an Environment act like a dictionary.  These have
    # the expected standard names for Python mapping objects.  Note that
    # we don't actually make an Environment a subclass of UserDict for
    # performance reasons.  Note also that we only supply methods for
    # dictionary functionality that we actually need and use.
    #######################################################################

    def __init__(self,
                 platform=None,
                 tools=None,
                 toolpath=None,
                 options=None,
                 **kw):
        """
        Initialization of a basic SCons construction environment,
        including setting up special construction variables like BUILDER,
        PLATFORM, etc., and searching for and applying available Tools.

        Note that we do *not* call the underlying base class
        (SubsitutionEnvironment) initialization, because we need to
        initialize things in a very specific order that doesn't work
        with the much simpler base class initialization.
        """
        if __debug__: logInstanceCreation(self, 'Environment.Base')
        self.fs = SCons.Node.FS.default_fs or SCons.Node.FS.FS()
        self.ans = SCons.Node.Alias.default_ans
        self.lookup_list = SCons.Node.arg2nodes_lookups
        self._dict = our_deepcopy(SCons.Defaults.ConstructionEnvironment)
        self._init_special()

        self._dict['BUILDERS'] = BuilderDict(self._dict['BUILDERS'], self)

        if platform is None:
            platform = self._dict.get('PLATFORM', None)
            if platform is None:
                platform = SCons.Platform.Platform()
        if SCons.Util.is_String(platform):
            platform = SCons.Platform.Platform(platform)
        self._dict['PLATFORM'] = str(platform)
        platform(self)

        # Apply the passed-in variables and customizable options to the
        # environment before calling the tools, because they may use
        # some of them during initialization.
        apply(self.Replace, (), kw)
        keys = kw.keys()
        if options:
            keys = keys + options.keys()
            options.Update(self)

        save = {}
        for k in keys:
            try:
                save[k] = self._dict[k]
            except KeyError:
                # No value may have been set if they tried to pass in a
                # reserved variable name like TARGETS.
                pass

        if tools is None:
            tools = self._dict.get('TOOLS', None)
            if tools is None:
                tools = ['default']
        apply_tools(self, tools, toolpath)

        # Now restore the passed-in variables and customized options
        # to the environment, since the values the user set explicitly
        # should override any values set by the tools.
        for key, val in save.items():
            self._dict[key] = val

    #######################################################################
    # Utility methods that are primarily for internal use by SCons.
    # These begin with lower-case letters.
    #######################################################################

    def get_builder(self, name):
        """Fetch the builder with the specified name from the environment.
        """
        try:
            return self._dict['BUILDERS'][name]
        except KeyError:
            return None

    def get_calculator(self):
        "__cacheable__"
        try:
            module = self._calc_module
            c = apply(SCons.Sig.Calculator, (module,), CalculatorArgs)
        except AttributeError:
            # Note that we're calling get_calculator() here, so the
            # DefaultEnvironment() must have a _calc_module attribute
            # to avoid infinite recursion.
            c = SCons.Defaults.DefaultEnvironment().get_calculator()
        return c

    def get_factory(self, factory, default='File'):
        """Return a factory function for creating Nodes for this
        construction environment.
        __cacheable__
        """
        name = default
        try:
            is_node = issubclass(factory, SCons.Node.Node)
        except TypeError:
            # The specified factory isn't a Node itself--it's
            # most likely None, or possibly a callable.
            pass
        else:
            if is_node:
                # The specified factory is a Node (sub)class.  Try to
                # return the FS method that corresponds to the Node's
                # name--that is, we return self.fs.Dir if they want a Dir,
                # self.fs.File for a File, etc.
                try: name = factory.__name__
                except AttributeError: pass
                else: factory = None
        if not factory:
            # They passed us None, or we picked up a name from a specified
            # class, so return the FS method.  (Note that we *don't*
            # use our own self.{Dir,File} methods because that would
            # cause env.subst() to be called twice on the file name,
            # interfering with files that have $$ in them.)
            factory = getattr(self.fs, name)
        return factory

    def _gsm(self):
        "__cacheable__"
        try:
            scanners = self._dict['SCANNERS']
        except KeyError:
            return None

        sm = {}
        # Reverse the scanner list so that, if multiple scanners
        # claim they can scan the same suffix, earlier scanners
        # in the list will overwrite later scanners, so that
        # the result looks like a "first match" to the user.
        if not SCons.Util.is_List(scanners):
            scanners = [scanners]
        else:
            scanners = scanners[:] # copy so reverse() doesn't mod original
        scanners.reverse()
        for scanner in scanners:
            for k in scanner.get_skeys(self):
                sm[k] = scanner
        return sm
        
    def get_scanner(self, skey):
        """Find the appropriate scanner given a key (usually a file suffix).
        """
        sm = self._gsm()
        try: return sm[skey]
        except (KeyError, TypeError): return None

    def _smd(self):
        "__reset_cache__"
        pass
    
    def scanner_map_delete(self, kw=None):
        """Delete the cached scanner map (if we need to).
        """
        if not kw is None and not kw.has_key('SCANNERS'):
            return
        self._smd()

    def _update(self, dict):
        """Update an environment's values directly, bypassing the normal
        checks that occur when users try to set items.
        __cache_reset__
        """
        self._dict.update(dict)

    def use_build_signature(self):
        try:
            return self._build_signature
        except AttributeError:
            b = SCons.Defaults.DefaultEnvironment()._build_signature
            self._build_signature = b
            return b

    #######################################################################
    # Public methods for manipulating an Environment.  These begin with
    # upper-case letters.  The essential characteristic of methods in
    # this section is that they do *not* have corresponding same-named
    # global functions.  For example, a stand-alone Append() function
    # makes no sense, because Append() is all about appending values to
    # an Environment's construction variables.
    #######################################################################

    def Append(self, **kw):
        """Append values to existing construction variables
        in an Environment.
        """
        kw = copy_non_reserved_keywords(kw)
        for key, val in kw.items():
            # It would be easier on the eyes to write this using
            # "continue" statements whenever we finish processing an item,
            # but Python 1.5.2 apparently doesn't let you use "continue"
            # within try:-except: blocks, so we have to nest our code.
            try:
                orig = self._dict[key]
            except KeyError:
                # No existing variable in the environment, so just set
                # it to the new value.
                self._dict[key] = val
            else:
                try:
                    # Check if the original looks like a dictionary.
                    # If it is, we can't just try adding the value because
                    # dictionaries don't have __add__() methods, and
                    # things like UserList will incorrectly coerce the
                    # original dict to a list (which we don't want).
                    update_dict = orig.update
                except AttributeError:
                    try:
                        # Most straightforward:  just try to add them
                        # together.  This will work in most cases, when the
                        # original and new values are of compatible types.
                        self._dict[key] = orig + val
                    except (KeyError, TypeError):
                        try:
                            # Check if the original is a list.
                            add_to_orig = orig.append
                        except AttributeError:
                            # The original isn't a list, but the new
                            # value is (by process of elimination),
                            # so insert the original in the new value
                            # (if there's one to insert) and replace
                            # the variable with it.
                            if orig:
                                val.insert(0, orig)
                            self._dict[key] = val
                        else:
                            # The original is a list, so append the new
                            # value to it (if there's a value to append).
                            if val:
                                add_to_orig(val)
                else:
                    # The original looks like a dictionary, so update it
                    # based on what we think the value looks like.
                    if SCons.Util.is_List(val):
                        for v in val:
                            orig[v] = None
                    else:
                        try:
                            update_dict(val)
                        except (AttributeError, TypeError, ValueError):
                            orig[val] = None
        self.scanner_map_delete(kw)

    def AppendENVPath(self, name, newpath, envname = 'ENV', sep = os.pathsep):
        """Append path elements to the path 'name' in the 'ENV'
        dictionary for this environment.  Will only add any particular
        path once, and will normpath and normcase all paths to help
        assure this.  This can also handle the case where the env
        variable is a list instead of a string.
        """

        orig = ''
        if self._dict.has_key(envname) and self._dict[envname].has_key(name):
            orig = self._dict[envname][name]

        nv = SCons.Util.AppendPath(orig, newpath, sep)
            
        if not self._dict.has_key(envname):
            self._dict[envname] = {}

        self._dict[envname][name] = nv

    def AppendUnique(self, **kw):
        """Append values to existing construction variables
        in an Environment, if they're not already there.
        """
        kw = copy_non_reserved_keywords(kw)
        for key, val in kw.items():
            if not self._dict.has_key(key) or self._dict[key] in ('', None):
                self._dict[key] = val
            elif SCons.Util.is_Dict(self._dict[key]) and \
                 SCons.Util.is_Dict(val):
                self._dict[key].update(val)
            elif SCons.Util.is_List(val):
                dk = self._dict[key]
                if not SCons.Util.is_List(dk):
                    dk = [dk]
                val = filter(lambda x, dk=dk: x not in dk, val)
                self._dict[key] = dk + val
            else:
                dk = self._dict[key]
                if SCons.Util.is_List(dk):
                    # By elimination, val is not a list.  Since dk is a
                    # list, wrap val in a list first.
                    if not val in dk:
                        self._dict[key] = dk + [val]
                else:
                    self._dict[key] = self._dict[key] + val
        self.scanner_map_delete(kw)

    def Clone(self, tools=[], toolpath=None, **kw):
        """Return a copy of a construction Environment.  The
        copy is like a Python "deep copy"--that is, independent
        copies are made recursively of each objects--except that
        a reference is copied when an object is not deep-copyable
        (like a function).  There are no references to any mutable
        objects in the original Environment.
        """
        clone = copy.copy(self)
        clone._dict = our_deepcopy(self._dict)
        try:
            cbd = clone._dict['BUILDERS']
            clone._dict['BUILDERS'] = BuilderDict(cbd, clone)
        except KeyError:
            pass
        
        apply_tools(clone, tools, toolpath)

        # Apply passed-in variables after the new tools.
        kw = copy_non_reserved_keywords(kw)
        new = {}
        for key, value in kw.items():
            new[key] = SCons.Subst.scons_subst_once(value, self, key)
        apply(clone.Replace, (), new)
        if __debug__: logInstanceCreation(self, 'Environment.EnvironmentClone')
        return clone

    def Copy(self, *args, **kw):
        return apply(self.Clone, args, kw)

    def Detect(self, progs):
        """Return the first available program in progs.  __cacheable__
        """
        if not SCons.Util.is_List(progs):
            progs = [ progs ]
        for prog in progs:
            path = self.WhereIs(prog)
            if path: return prog
        return None

    def Dictionary(self, *args):
        if not args:
            return self._dict
        dlist = map(lambda x, s=self: s._dict[x], args)
        if len(dlist) == 1:
            dlist = dlist[0]
        return dlist

    def Dump(self, key = None):
        """
        Using the standard Python pretty printer, dump the contents of the
        scons build environment to stdout.

        If the key passed in is anything other than None, then that will
        be used as an index into the build environment dictionary and
        whatever is found there will be fed into the pretty printer. Note
        that this key is case sensitive.
        """
        import pprint
        pp = pprint.PrettyPrinter(indent=2)
        if key:
            dict = self.Dictionary(key)
        else:
            dict = self.Dictionary()
        return pp.pformat(dict)

    def FindIxes(self, paths, prefix, suffix):
        """
        Search a list of paths for something that matches the prefix and suffix.

        paths - the list of paths or nodes.
        prefix - construction variable for the prefix.
        suffix - construction variable for the suffix.
        """

        suffix = self.subst('$'+suffix)
        prefix = self.subst('$'+prefix)

        for path in paths:
            dir,name = os.path.split(str(path))
            if name[:len(prefix)] == prefix and name[-len(suffix):] == suffix: 
                return path

    def ParseConfig(self, command, function=None, unique=1):
        """
        Use the specified function to parse the output of the command
        in order to modify the current environment.  The 'command' can
        be a string or a list of strings representing a command and
        its arguments.  'Function' is an optional argument that takes
        the environment, the output of the command, and the unique flag.
        If no function is specified, MergeFlags, which treats the output
        as the result of a typical 'X-config' command (i.e. gtk-config),
        will merge the output into the appropriate variables.
        """
        if function is None:
            def parse_conf(env, cmd, unique=unique):
                return env.MergeFlags(cmd, unique)
            function = parse_conf
        if SCons.Util.is_List(command):
            command = string.join(command)
        command = self.subst(command)
        return function(self, self.backtick(command))

    def ParseDepends(self, filename, must_exist=None, only_one=0):
        """
        Parse a mkdep-style file for explicit dependencies.  This is
        completely abusable, and should be unnecessary in the "normal"
        case of proper SCons configuration, but it may help make
        the transition from a Make hierarchy easier for some people
        to swallow.  It can also be genuinely useful when using a tool
        that can write a .d file, but for which writing a scanner would
        be too complicated.
        """
        filename = self.subst(filename)
        try:
            fp = open(filename, 'r')
        except IOError:
            if must_exist:
                raise
            return
        lines = SCons.Util.LogicalLines(fp).readlines()
        lines = filter(lambda l: l[0] != '#', lines)
        tdlist = []
        for line in lines:
            try:
                target, depends = string.split(line, ':', 1)
            except (AttributeError, TypeError, ValueError):
                # Python 1.5.2 throws TypeError if line isn't a string,
                # Python 2.x throws AttributeError because it tries
                # to call line.split().  Either can throw ValueError
                # if the line doesn't split into two or more elements.
                pass
            else:
                tdlist.append((string.split(target), string.split(depends)))
        if only_one:
            targets = reduce(lambda x, y: x+y, map(lambda p: p[0], tdlist))
            if len(targets) > 1:
                raise SCons.Errors.UserError, "More than one dependency target found in `%s':  %s" % (filename, targets)
        for target, depends in tdlist:
            self.Depends(target, depends)

    def Platform(self, platform):
        platform = self.subst(platform)
        return SCons.Platform.Platform(platform)(self)

    def Prepend(self, **kw):
        """Prepend values to existing construction variables
        in an Environment.
        """
        kw = copy_non_reserved_keywords(kw)
        for key, val in kw.items():
            # It would be easier on the eyes to write this using
            # "continue" statements whenever we finish processing an item,
            # but Python 1.5.2 apparently doesn't let you use "continue"
            # within try:-except: blocks, so we have to nest our code.
            try:
                orig = self._dict[key]
            except KeyError:
                # No existing variable in the environment, so just set
                # it to the new value.
                self._dict[key] = val
            else:
                try:
                    # Check if the original looks like a dictionary.
                    # If it is, we can't just try adding the value because
                    # dictionaries don't have __add__() methods, and
                    # things like UserList will incorrectly coerce the
                    # original dict to a list (which we don't want).
                    update_dict = orig.update
                except AttributeError:
                    try:
                        # Most straightforward:  just try to add them
                        # together.  This will work in most cases, when the
                        # original and new values are of compatible types.
                        self._dict[key] = val + orig
                    except (KeyError, TypeError):
                        try:
                            # Check if the added value is a list.
                            add_to_val = val.append
                        except AttributeError:
                            # The added value isn't a list, but the
                            # original is (by process of elimination),
                            # so insert the the new value in the original
                            # (if there's one to insert).
                            if val:
                                orig.insert(0, val)
                        else:
                            # The added value is a list, so append
                            # the original to it (if there's a value
                            # to append).
                            if orig:
                                add_to_val(orig)
                            self._dict[key] = val
                else:
                    # The original looks like a dictionary, so update it
                    # based on what we think the value looks like.
                    if SCons.Util.is_List(val):
                        for v in val:
                            orig[v] = None
                    else:
                        try:
                            update_dict(val)
                        except (AttributeError, TypeError, ValueError):
                            orig[val] = None
        self.scanner_map_delete(kw)

    def PrependENVPath(self, name, newpath, envname = 'ENV', sep = os.pathsep):
        """Prepend path elements to the path 'name' in the 'ENV'
        dictionary for this environment.  Will only add any particular
        path once, and will normpath and normcase all paths to help
        assure this.  This can also handle the case where the env
        variable is a list instead of a string.
        """

        orig = ''
        if self._dict.has_key(envname) and self._dict[envname].has_key(name):
            orig = self._dict[envname][name]

        nv = SCons.Util.PrependPath(orig, newpath, sep)
            
        if not self._dict.has_key(envname):
            self._dict[envname] = {}

        self._dict[envname][name] = nv

    def PrependUnique(self, **kw):
        """Append values to existing construction variables
        in an Environment, if they're not already there.
        """
        kw = copy_non_reserved_keywords(kw)
        for key, val in kw.items():
            if not self._dict.has_key(key) or self._dict[key] in ('', None):
                self._dict[key] = val
            elif SCons.Util.is_Dict(self._dict[key]) and \
                 SCons.Util.is_Dict(val):
                self._dict[key].update(val)
            elif SCons.Util.is_List(val):
                dk = self._dict[key]
                if not SCons.Util.is_List(dk):
                    dk = [dk]
                val = filter(lambda x, dk=dk: x not in dk, val)
                self._dict[key] = val + dk
            else:
                dk = self._dict[key]
                if SCons.Util.is_List(dk):
                    # By elimination, val is not a list.  Since dk is a
                    # list, wrap val in a list first.
                    if not val in dk:
                        self._dict[key] = [val] + dk
                else:
                    self._dict[key] = val + dk
        self.scanner_map_delete(kw)

    def Replace(self, **kw):
        """Replace existing construction variables in an Environment
        with new construction variables and/or values.
        """
        try:
            kwbd = our_deepcopy(kw['BUILDERS'])
            del kw['BUILDERS']
            self.__setitem__('BUILDERS', kwbd)
        except KeyError:
            pass
        kw = copy_non_reserved_keywords(kw)
        self._update(our_deepcopy(kw))
        self.scanner_map_delete(kw)

    def ReplaceIxes(self, path, old_prefix, old_suffix, new_prefix, new_suffix):
        """
        Replace old_prefix with new_prefix and old_suffix with new_suffix.

        env - Environment used to interpolate variables.
        path - the path that will be modified.
        old_prefix - construction variable for the old prefix.
        old_suffix - construction variable for the old suffix.
        new_prefix - construction variable for the new prefix.
        new_suffix - construction variable for the new suffix.
        """
        old_prefix = self.subst('$'+old_prefix)
        old_suffix = self.subst('$'+old_suffix)

        new_prefix = self.subst('$'+new_prefix)
        new_suffix = self.subst('$'+new_suffix)

        dir,name = os.path.split(str(path))
        if name[:len(old_prefix)] == old_prefix:
            name = name[len(old_prefix):]
        if name[-len(old_suffix):] == old_suffix:
            name = name[:-len(old_suffix)]
        return os.path.join(dir, new_prefix+name+new_suffix)

    def SetDefault(self, **kw):
        for k in kw.keys():
            if self._dict.has_key(k):
                del kw[k]
        apply(self.Replace, (), kw)

    def Tool(self, tool, toolpath=None, **kw):
        if SCons.Util.is_String(tool):
            tool = self.subst(tool)
            if toolpath is None:
                toolpath = self.get('toolpath', [])
            toolpath = map(self.subst, toolpath)
            tool = apply(SCons.Tool.Tool, (tool, toolpath), kw)
        tool(self)

    def WhereIs(self, prog, path=None, pathext=None, reject=[]):
        """Find prog in the path.  __cacheable__
        """
        if path is None:
            try:
                path = self['ENV']['PATH']
            except KeyError:
                pass
        elif SCons.Util.is_String(path):
            path = self.subst(path)
        if pathext is None:
            try:
                pathext = self['ENV']['PATHEXT']
            except KeyError:
                pass
        elif SCons.Util.is_String(pathext):
            pathext = self.subst(pathext)
        path = SCons.Util.WhereIs(prog, path, pathext, reject)
        if path: return path
        return None

    #######################################################################
    # Public methods for doing real "SCons stuff" (manipulating
    # dependencies, setting attributes on targets, etc.).  These begin
    # with upper-case letters.  The essential characteristic of methods
    # in this section is that they all *should* have corresponding
    # same-named global functions.
    #######################################################################

    def Action(self, *args, **kw):
        def subst_string(a, self=self):
            if SCons.Util.is_String(a):
                a = self.subst(a)
            return a
        nargs = map(subst_string, args)
        nkw = self.subst_kw(kw)
        return apply(SCons.Action.Action, nargs, nkw)

    def AddPreAction(self, files, action):
        nodes = self.arg2nodes(files, self.fs.Entry)
        action = SCons.Action.Action(action)
        uniq = {}
        for executor in map(lambda n: n.get_executor(), nodes):
            uniq[executor] = 1
        for executor in uniq.keys():
            executor.add_pre_action(action)
        return nodes

    def AddPostAction(self, files, action):
        nodes = self.arg2nodes(files, self.fs.Entry)
        action = SCons.Action.Action(action)
        uniq = {}
        for executor in map(lambda n: n.get_executor(), nodes):
            uniq[executor] = 1
        for executor in uniq.keys():
            executor.add_post_action(action)
        return nodes

    def Alias(self, target, source=[], action=None, **kw):
        tlist = self.arg2nodes(target, self.ans.Alias)
        if not SCons.Util.is_List(source):
            source = [source]
        source = filter(None, source)

        if not action:
            if not source:
                # There are no source files and no action, so just
                # return a target list of classic Alias Nodes, without
                # any builder.  The externally visible effect is that
                # this will make the wrapping Script.BuildTask class
                # say that there's "Nothing to be done" for this Alias,
                # instead of that it's "up to date."
                return tlist

            # No action, but there are sources.  Re-call all the target
            # builders to add the sources to each target.
            result = []
            for t in tlist:
                bld = t.get_builder(AliasBuilder)
                result.extend(bld(self, t, source))
            return result

        nkw = self.subst_kw(kw)
        nkw.update({
            'action'            : SCons.Action.Action(action),
            'source_factory'    : self.fs.Entry,
            'multi'             : 1,
            'is_explicit'       : None,
        })
        bld = apply(SCons.Builder.Builder, (), nkw)

        # Apply the Builder separately to each target so that the Aliases
        # stay separate.  If we did one "normal" Builder call with the
        # whole target list, then all of the target Aliases would be
        # associated under a single Executor.
        result = []
        for t in tlist:
            # Calling the convert() method will cause a new Executor to be
            # created from scratch, so we have to explicitly initialize
            # it with the target's existing sources, plus our new ones,
            # so nothing gets lost.
            b = t.get_builder()
            if b is None or b is AliasBuilder:
                b = bld
            else:
                nkw['action'] = b.action + action
                b = apply(SCons.Builder.Builder, (), nkw)
            t.convert()
            result.extend(b(self, t, t.sources + source))
        return result

    def AlwaysBuild(self, *targets):
        tlist = []
        for t in targets:
            tlist.extend(self.arg2nodes(t, self.fs.File))
        for t in tlist:
            t.set_always_build()
        return tlist

    def BuildDir(self, build_dir, src_dir, duplicate=1):
        build_dir = self.arg2nodes(build_dir, self.fs.Dir)[0]
        src_dir = self.arg2nodes(src_dir, self.fs.Dir)[0]
        self.fs.BuildDir(build_dir, src_dir, duplicate)

    def Builder(self, **kw):
        nkw = self.subst_kw(kw)
        return apply(SCons.Builder.Builder, [], nkw)

    def CacheDir(self, path):
        self.fs.CacheDir(self.subst(path))

    def Clean(self, targets, files):
        global CleanTargets
        tlist = self.arg2nodes(targets, self.fs.Entry)
        flist = self.arg2nodes(files, self.fs.Entry)
        for t in tlist:
            try:
                CleanTargets[t].extend(flist)
            except KeyError:
                CleanTargets[t] = flist

    def Configure(self, *args, **kw):
        nargs = [self]
        if args:
            nargs = nargs + self.subst_list(args)[0]
        nkw = self.subst_kw(kw)
        nkw['_depth'] = kw.get('_depth', 0) + 1
        try:
            nkw['custom_tests'] = self.subst_kw(nkw['custom_tests'])
        except KeyError:
            pass
        return apply(SCons.SConf.SConf, nargs, nkw)

    def Command(self, target, source, action, **kw):
        """Builds the supplied target files from the supplied
        source files using the supplied action.  Action may
        be any type that the Builder constructor will accept
        for an action."""
        bkw = {
            'action' : action,
            'target_factory' : self.fs.Entry,
            'source_factory' : self.fs.Entry,
        }
        try: bkw['source_scanner'] = kw['source_scanner']
        except KeyError: pass
        else: del kw['source_scanner']
        bld = apply(SCons.Builder.Builder, (), bkw)
        return apply(bld, (self, target, source), kw)

    def Depends(self, target, dependency):
        """Explicity specify that 'target's depend on 'dependency'."""
        tlist = self.arg2nodes(target, self.fs.Entry)
        dlist = self.arg2nodes(dependency, self.fs.Entry)
        for t in tlist:
            t.add_dependency(dlist)
        return tlist

    def Dir(self, name, *args, **kw):
        """
        """
        return apply(self.fs.Dir, (self.subst(name),) + args, kw)

    def NoClean(self, *targets):
        """Tags a target so that it will not be cleaned by -c"""
        tlist = []
        for t in targets:
            tlist.extend(self.arg2nodes(t, self.fs.Entry))
        for t in tlist:
            t.set_noclean()
        return tlist

    def Entry(self, name, *args, **kw):
        """
        """
        return apply(self.fs.Entry, (self.subst(name),) + args, kw)

    def Environment(self, **kw):
        return apply(SCons.Environment.Environment, [], self.subst_kw(kw))

    def Execute(self, action, *args, **kw):
        """Directly execute an action through an Environment
        """
        action = apply(self.Action, (action,) + args, kw)
        return action([], [], self)

    def File(self, name, *args, **kw):
        """
        """
        return apply(self.fs.File, (self.subst(name),) + args, kw)

    def FindFile(self, file, dirs):
        file = self.subst(file)
        nodes = self.arg2nodes(dirs, self.fs.Dir)
        return SCons.Node.FS.find_file(file, tuple(nodes))

    def Flatten(self, sequence):
        return SCons.Util.flatten(sequence)

    def GetBuildPath(self, files):
        result = map(str, self.arg2nodes(files, self.fs.Entry))
        if SCons.Util.is_List(files):
            return result
        else:
            return result[0]

    def Ignore(self, target, dependency):
        """Ignore a dependency."""
        tlist = self.arg2nodes(target, self.fs.Entry)
        dlist = self.arg2nodes(dependency, self.fs.Entry)
        for t in tlist:
            t.add_ignore(dlist)
        return tlist

    def Install(self, dir, source):
        """Install specified files in the given directory."""
        try:
            dnodes = self.arg2nodes(dir, self.fs.Dir)
        except TypeError:
            fmt = "Target `%s' of Install() is a file, but should be a directory.  Perhaps you have the Install() arguments backwards?"
            raise SCons.Errors.UserError, fmt % str(dir)
        try:
            sources = self.arg2nodes(source, self.fs.Entry)
        except TypeError:
            if SCons.Util.is_List(source):
                s = repr(map(str, source))
            else:
                s = str(source)
            fmt = "Source `%s' of Install() is neither a file nor a directory.  Install() source must be one or more files or directories"
            raise SCons.Errors.UserError, fmt % s
        tgt = []
        for dnode in dnodes:
            for src in sources:
                target = self.fs.Entry(src.name, dnode)
                tgt.extend(InstallBuilder(self, target, src))
        return tgt

    def InstallAs(self, target, source):
        """Install sources as targets."""
        sources = self.arg2nodes(source, self.fs.Entry)
        targets = self.arg2nodes(target, self.fs.Entry)
        if len(sources) != len(targets):
            if not SCons.Util.is_List(target):
                target = [target]
            if not SCons.Util.is_List(source):
                source = [source]
            t = repr(map(str, target))
            s = repr(map(str, source))
            fmt = "Target (%s) and source (%s) lists of InstallAs() must be the same length."
            raise SCons.Errors.UserError, fmt % (t, s)
        result = []
        for src, tgt in map(lambda x, y: (x, y), sources, targets):
            result.extend(InstallBuilder(self, tgt, src))
        return result

    def Literal(self, string):
        return SCons.Subst.Literal(string)

    def Local(self, *targets):
        ret = []
        for targ in targets:
            if isinstance(targ, SCons.Node.Node):
                targ.set_local()
                ret.append(targ)
            else:
                for t in self.arg2nodes(targ, self.fs.Entry):
                   t.set_local()
                   ret.append(t)
        return ret

    def Precious(self, *targets):
        tlist = []
        for t in targets:
            tlist.extend(self.arg2nodes(t, self.fs.Entry))
        for t in tlist:
            t.set_precious()
        return tlist

    def Repository(self, *dirs, **kw):
        dirs = self.arg2nodes(list(dirs), self.fs.Dir)
        apply(self.fs.Repository, dirs, kw)

    def Scanner(self, *args, **kw):
        nargs = []
        for arg in args:
            if SCons.Util.is_String(arg):
                arg = self.subst(arg)
            nargs.append(arg)
        nkw = self.subst_kw(kw)
        return apply(SCons.Scanner.Scanner, nargs, nkw)

    def SConsignFile(self, name=".sconsign", dbm_module=None):
        if not name is None:
            name = self.subst(name)
            if not os.path.isabs(name):
                name = os.path.join(str(self.fs.SConstruct_dir), name)
        SCons.SConsign.File(name, dbm_module)

    def SideEffect(self, side_effect, target):
        """Tell scons that side_effects are built as side 
        effects of building targets."""
        side_effects = self.arg2nodes(side_effect, self.fs.Entry)
        targets = self.arg2nodes(target, self.fs.Entry)

        for side_effect in side_effects:
            if side_effect.multiple_side_effect_has_builder():
                raise SCons.Errors.UserError, "Multiple ways to build the same target were specified for: %s" % str(side_effect)
            side_effect.add_source(targets)
            side_effect.side_effect = 1
            self.Precious(side_effect)
            for target in targets:
                target.side_effects.append(side_effect)
        return side_effects

    def SourceCode(self, entry, builder):
        """Arrange for a source code builder for (part of) a tree."""
        entries = self.arg2nodes(entry, self.fs.Entry)
        for entry in entries:
            entry.set_src_builder(builder)
        return entries

    def SourceSignatures(self, type):
        type = self.subst(type)
        if type == 'MD5':
            import SCons.Sig.MD5
            self._calc_module = SCons.Sig.MD5
        elif type == 'timestamp':
            import SCons.Sig.TimeStamp
            self._calc_module = SCons.Sig.TimeStamp
        else:
            raise UserError, "Unknown source signature type '%s'"%type

    def Split(self, arg):
        """This function converts a string or list into a list of strings
        or Nodes.  This makes things easier for users by allowing files to
        be specified as a white-space separated list to be split.
        The input rules are:
            - A single string containing names separated by spaces. These will be
              split apart at the spaces.
            - A single Node instance
            - A list containing either strings or Node instances. Any strings
              in the list are not split at spaces.
        In all cases, the function returns a list of Nodes and strings."""
        if SCons.Util.is_List(arg):
            return map(self.subst, arg)
        elif SCons.Util.is_String(arg):
            return string.split(self.subst(arg))
        else:
            return [self.subst(arg)]

    def TargetSignatures(self, type):
        type = self.subst(type)
        if type == 'build':
            self._build_signature = 1
        elif type == 'content':
            self._build_signature = 0
        else:
            raise SCons.Errors.UserError, "Unknown target signature type '%s'"%type

    def Value(self, value, built_value=None):
        """
        """
        return SCons.Node.Python.Value(value, built_value)

class OverrideEnvironment(Base):
    """A proxy that overrides variables in a wrapped construction
    environment by returning values from an overrides dictionary in
    preference to values from the underlying subject environment.

    This is a lightweight (I hope) proxy that passes through most use of
    attributes to the underlying Environment.Base class, but has just
    enough additional methods defined to act like a real construction
    environment with overridden values.  It can wrap either a Base
    construction environment, or another OverrideEnvironment, which
    can in turn nest arbitrary OverrideEnvironments...

    Note that we do *not* call the underlying base class
    (SubsitutionEnvironment) initialization, because we get most of those
    from proxying the attributes of the subject construction environment.
    But because we subclass SubstitutionEnvironment, this class also
    has inherited arg2nodes() and subst*() methods; those methods can't
    be proxied because they need *this* object's methods to fetch the
    values from the overrides dictionary.
    """

    if SCons.Memoize.use_memoizer:
        __metaclass__ = SCons.Memoize.Memoized_Metaclass

    def __init__(self, subject, overrides={}):
        if __debug__: logInstanceCreation(self, 'Environment.OverrideEnvironment')
        self.__dict__['__subject'] = subject
        self.__dict__['overrides'] = overrides

    # Methods that make this class act like a proxy.
    def __getattr__(self, name):
        return getattr(self.__dict__['__subject'], name)
    def __setattr__(self, name, value):
        return setattr(self.__dict__['__subject'], name, value)

    # Methods that make this class act like a dictionary.
    def __getitem__(self, key):
        try:
            return self.__dict__['overrides'][key]
        except KeyError:
            return self.__dict__['__subject'].__getitem__(key)
    def __setitem__(self, key, value):
        if not SCons.Util.is_valid_construction_var(key):
            raise SCons.Errors.UserError, "Illegal construction variable `%s'" % key
        self.__dict__['overrides'][key] = value
    def __delitem__(self, key):
        try:
            del self.__dict__['overrides'][key]
        except KeyError:
            deleted = 0
        else:
            deleted = 1
        try:
            result = self.__dict__['__subject'].__delitem__(key)
        except KeyError:
            if not deleted:
                raise
            result = None
        return result
    def get(self, key, default=None):
        """Emulates the get() method of dictionaries."""
        try:
            return self.__dict__['overrides'][key]
        except KeyError:
            return self.__dict__['__subject'].get(key, default)
    def has_key(self, key):
        try:
            self.__dict__['overrides'][key]
            return 1
        except KeyError:
            return self.__dict__['__subject'].has_key(key)
    def Dictionary(self):
        """Emulates the items() method of dictionaries."""
        d = self.__dict__['__subject'].Dictionary().copy()
        d.update(self.__dict__['overrides'])
        return d
    def items(self):
        """Emulates the items() method of dictionaries."""
        return self.Dictionary().items()

    # Overridden private construction environment methods.
    def _update(self, dict):
        """Update an environment's values directly, bypassing the normal
        checks that occur when users try to set items.
        """
        self.__dict__['overrides'].update(dict)

    def gvars(self):
        return self.__dict__['__subject'].gvars()

    def lvars(self):
        lvars = self.__dict__['__subject'].lvars()
        lvars.update(self.__dict__['overrides'])
        return lvars

    # Overridden public construction environment methods.
    def Replace(self, **kw):
        kw = copy_non_reserved_keywords(kw)
        self.__dict__['overrides'].update(our_deepcopy(kw))

# The entry point that will be used by the external world
# to refer to a construction environment.  This allows the wrapper
# interface to extend a construction environment for its own purposes
# by subclassing SCons.Environment.Base and then assigning the
# class to SCons.Environment.Environment.

Environment = Base

# An entry point for returning a proxy subclass instance that overrides
# the subst*() methods so they don't actually perform construction
# variable substitution.  This is specifically intended to be the shim
# layer in between global function calls (which don't want construction
# variable substitution) and the DefaultEnvironment() (which would
# substitute variables if left to its own devices)."""
#
# We have to wrap this in a function that allows us to delay definition of
# the class until it's necessary, so that when it subclasses Environment
# it will pick up whatever Environment subclass the wrapper interface
# might have assigned to SCons.Environment.Environment.

def NoSubstitutionProxy(subject):
    class _NoSubstitutionProxy(Environment):
        def __init__(self, subject):
            self.__dict__['__subject'] = subject
        def __getattr__(self, name):
            return getattr(self.__dict__['__subject'], name)
        def __setattr__(self, name, value):
            return setattr(self.__dict__['__subject'], name, value)
        def raw_to_mode(self, dict):
            try:
                raw = dict['raw']
            except KeyError:
                pass
            else:
                del dict['raw']
                dict['mode'] = raw
        def subst(self, string, *args, **kwargs):
            return string
        def subst_kw(self, kw, *args, **kwargs):
            return kw
        def subst_list(self, string, *args, **kwargs):
            nargs = (string, self,) + args
            nkw = kwargs.copy()
            nkw['gvars'] = {}
            self.raw_to_mode(nkw)
            return apply(SCons.Subst.scons_subst_list, nargs, nkw)
        def subst_target_source(self, string, *args, **kwargs):
            nargs = (string, self,) + args
            nkw = kwargs.copy()
            nkw['gvars'] = {}
            self.raw_to_mode(nkw)
            return apply(SCons.Subst.scons_subst, nargs, nkw)
    return _NoSubstitutionProxy(subject)

if SCons.Memoize.use_old_memoization():
    _Base = Base
    class Base(SCons.Memoize.Memoizer, _Base):
        def __init__(self, *args, **kw):
            SCons.Memoize.Memoizer.__init__(self)
            apply(_Base.__init__, (self,)+args, kw)
    Environment = Base

