"""SCons.Subst

SCons string substitution.

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

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/Subst.py 0.96.93.D001 2006/11/06 08:31:54 knight"

import __builtin__
import re
import string
import types
import UserList

import SCons.Errors

from SCons.Util import is_String, is_List, is_Tuple

# Indexed by the SUBST_* constants below.
_strconv = [SCons.Util.to_String,
            SCons.Util.to_String,
            SCons.Util.to_String_for_signature]

class Literal:
    """A wrapper for a string.  If you use this object wrapped
    around a string, then it will be interpreted as literal.
    When passed to the command interpreter, all special
    characters will be escaped."""
    def __init__(self, lstr):
        self.lstr = lstr

    def __str__(self):
        return self.lstr

    def escape(self, escape_func):
        return escape_func(self.lstr)

    def for_signature(self):
        return self.lstr

    def is_literal(self):
        return 1

class SpecialAttrWrapper:
    """This is a wrapper for what we call a 'Node special attribute.'
    This is any of the attributes of a Node that we can reference from
    Environment variable substitution, such as $TARGET.abspath or
    $SOURCES[1].filebase.  We implement the same methods as Literal
    so we can handle special characters, plus a for_signature method,
    such that we can return some canonical string during signature
    calculation to avoid unnecessary rebuilds."""

    def __init__(self, lstr, for_signature=None):
        """The for_signature parameter, if supplied, will be the
        canonical string we return from for_signature().  Else
        we will simply return lstr."""
        self.lstr = lstr
        if for_signature:
            self.forsig = for_signature
        else:
            self.forsig = lstr

    def __str__(self):
        return self.lstr

    def escape(self, escape_func):
        return escape_func(self.lstr)

    def for_signature(self):
        return self.forsig

    def is_literal(self):
        return 1

def quote_spaces(arg):
    """Generic function for putting double quotes around any string that
    has white space in it."""
    if ' ' in arg or '\t' in arg:
        return '"%s"' % arg
    else:
        return str(arg)

class CmdStringHolder(SCons.Util.UserString):
    """This is a special class used to hold strings generated by
    scons_subst() and scons_subst_list().  It defines a special method
    escape().  When passed a function with an escape algorithm for a
    particular platform, it will return the contained string with the
    proper escape sequences inserted.

    This should really be a subclass of UserString, but that module
    doesn't exist in Python 1.5.2."""
    def __init__(self, cmd, literal=None):
        SCons.Util.UserString.__init__(self, cmd)
        self.literal = literal

    def is_literal(self):
        return self.literal

    def escape(self, escape_func, quote_func=quote_spaces):
        """Escape the string with the supplied function.  The
        function is expected to take an arbitrary string, then
        return it with all special characters escaped and ready
        for passing to the command interpreter.

        After calling this function, the next call to str() will
        return the escaped string.
        """

        if self.is_literal():
            return escape_func(self.data)
        elif ' ' in self.data or '\t' in self.data:
            return quote_func(self.data)
        else:
            return self.data

def escape_list(list, escape_func):
    """Escape a list of arguments by running the specified escape_func
    on every object in the list that has an escape() method."""
    def escape(obj, escape_func=escape_func):
        try:
            e = obj.escape
        except AttributeError:
            return obj
        else:
            return e(escape_func)
    return map(escape, list)

class NLWrapper:
    """A wrapper class that delays turning a list of sources or targets
    into a NodeList until it's needed.  The specified function supplied
    when the object is initialized is responsible for turning raw nodes
    into proxies that implement the special attributes like .abspath,
    .source, etc.  This way, we avoid creating those proxies just
    "in case" someone is going to use $TARGET or the like, and only
    go through the trouble if we really have to.

    In practice, this might be a wash performance-wise, but it's a little
    cleaner conceptually...
    """
    
    def __init__(self, list, func):
        self.list = list
        self.func = func
    def _return_nodelist(self):
        return self.nodelist
    def _gen_nodelist(self):
        list = self.list
        if list is None:
            list = []
        elif not is_List(list) and not is_Tuple(list):
            list = [list]
        # The map(self.func) call is what actually turns
        # a list into appropriate proxies.
        self.nodelist = SCons.Util.NodeList(map(self.func, list))
        self._create_nodelist = self._return_nodelist
        return self.nodelist
    _create_nodelist = _gen_nodelist
    

class Targets_or_Sources(UserList.UserList):
    """A class that implements $TARGETS or $SOURCES expansions by in turn
    wrapping a NLWrapper.  This class handles the different methods used
    to access the list, calling the NLWrapper to create proxies on demand.

    Note that we subclass UserList.UserList purely so that the is_List()
    function will identify an object of this class as a list during
    variable expansion.  We're not really using any UserList.UserList
    methods in practice.
    """
    def __init__(self, nl):
        self.nl = nl
    def __getattr__(self, attr):
        nl = self.nl._create_nodelist()
        return getattr(nl, attr)
    def __getitem__(self, i):
        nl = self.nl._create_nodelist()
        return nl[i]
    def __getslice__(self, i, j):
        nl = self.nl._create_nodelist()
        i = max(i, 0); j = max(j, 0)
        return nl[i:j]
    def __str__(self):
        nl = self.nl._create_nodelist()
        return str(nl)
    def __repr__(self):
        nl = self.nl._create_nodelist()
        return repr(nl)

class Target_or_Source:
    """A class that implements $TARGET or $SOURCE expansions by in turn
    wrapping a NLWrapper.  This class handles the different methods used
    to access an individual proxy Node, calling the NLWrapper to create
    a proxy on demand.
    """
    def __init__(self, nl):
        self.nl = nl
    def __getattr__(self, attr):
        nl = self.nl._create_nodelist()
        try:
            nl0 = nl[0]
        except IndexError:
            # If there is nothing in the list, then we have no attributes to
            # pass through, so raise AttributeError for everything.
            raise AttributeError, "NodeList has no attribute: %s" % attr
        return getattr(nl0, attr)
    def __str__(self):
        nl = self.nl._create_nodelist()
        if nl:
            return str(nl[0])
        return ''
    def __repr__(self):
        nl = self.nl._create_nodelist()
        if nl:
            return repr(nl[0])
        return ''

def subst_dict(target, source):
    """Create a dictionary for substitution of special
    construction variables.

    This translates the following special arguments:

    target - the target (object or array of objects),
             used to generate the TARGET and TARGETS
             construction variables

    source - the source (object or array of objects),
             used to generate the SOURCES and SOURCE
             construction variables
    """
    dict = {}

    if target:
        tnl = NLWrapper(target, lambda x: x.get_subst_proxy())
        dict['TARGETS'] = Targets_or_Sources(tnl)
        dict['TARGET'] = Target_or_Source(tnl)
    else:
        dict['TARGETS'] = None
        dict['TARGET'] = None

    if source:
        def get_src_subst_proxy(node):
            try:
                rfile = node.rfile
            except AttributeError:
                pass
            else:
                node = rfile()
            return node.get_subst_proxy()
        snl = NLWrapper(source, get_src_subst_proxy)
        dict['SOURCES'] = Targets_or_Sources(snl)
        dict['SOURCE'] = Target_or_Source(snl)
    else:
        dict['SOURCES'] = None
        dict['SOURCE'] = None

    return dict

# Constants for the "mode" parameter to scons_subst_list() and
# scons_subst().  SUBST_RAW gives the raw command line.  SUBST_CMD
# gives a command line suitable for passing to a shell.  SUBST_SIG
# gives a command line appropriate for calculating the signature
# of a command line...if this changes, we should rebuild.
SUBST_CMD = 0
SUBST_RAW = 1
SUBST_SIG = 2

_rm = re.compile(r'\$[()]')
_remove = re.compile(r'\$\([^\$]*(\$[^\)][^\$]*)*\$\)')

# Indexed by the SUBST_* constants above.
_regex_remove = [ _rm, None, _remove ]

# Regular expressions for splitting strings and handling substitutions,
# for use by the scons_subst() and scons_subst_list() functions:
#
# The first expression compiled matches all of the $-introduced tokens
# that we need to process in some way, and is used for substitutions.
# The expressions it matches are:
#
#       "$$"
#       "$("
#       "$)"
#       "$variable"             [must begin with alphabetic or underscore]
#       "${any stuff}"
#
# The second expression compiled is used for splitting strings into tokens
# to be processed, and it matches all of the tokens listed above, plus
# the following that affect how arguments do or don't get joined together:
#
#       "   "                   [white space]
#       "non-white-space"       [without any dollar signs]
#       "$"                     [single dollar sign]
#
_dollar_exps_str = r'\$[\$\(\)]|\$[_a-zA-Z][\.\w]*|\${[^}]*}'
_dollar_exps = re.compile(r'(%s)' % _dollar_exps_str)
_separate_args = re.compile(r'(%s|\s+|[^\s\$]+|\$)' % _dollar_exps_str)

# This regular expression is used to replace strings of multiple white
# space characters in the string result from the scons_subst() function.
_space_sep = re.compile(r'[\t ]+(?![^{]*})')

def scons_subst(strSubst, env, mode=SUBST_RAW, target=None, source=None, gvars={}, lvars={}, conv=None):
    """Expand a string containing construction variable substitutions.

    This is the work-horse function for substitutions in file names
    and the like.  The companion scons_subst_list() function (below)
    handles separating command lines into lists of arguments, so see
    that function if that's what you're looking for.
    """
    if type(strSubst) == types.StringType and string.find(strSubst, '$') < 0:
        return strSubst

    class StringSubber:
        """A class to construct the results of a scons_subst() call.

        This binds a specific construction environment, mode, target and
        source with two methods (substitute() and expand()) that handle
        the expansion.
        """
        def __init__(self, env, mode, target, source, conv, gvars):
            self.env = env
            self.mode = mode
            self.target = target
            self.source = source
            self.conv = conv
            self.gvars = gvars

        def expand(self, s, lvars):
            """Expand a single "token" as necessary, returning an
            appropriate string containing the expansion.

            This handles expanding different types of things (strings,
            lists, callables) appropriately.  It calls the wrapper
            substitute() method to re-expand things as necessary, so that
            the results of expansions of side-by-side strings still get
            re-evaluated separately, not smushed together.
            """
            if is_String(s):
                try:
                    s0, s1 = s[:2]
                except (IndexError, ValueError):
                    return s
                if s0 != '$':
                    return s
                if s1 == '$':
                    return '$'
                elif s1 in '()':
                    return s
                else:
                    key = s[1:]
                    if key[0] == '{' or string.find(key, '.') >= 0:
                        if key[0] == '{':
                            key = key[1:-1]
                        try:
                            s = eval(key, self.gvars, lvars)
                        except AttributeError, e:
                            raise SCons.Errors.UserError, \
                                  "Error trying to evaluate `%s': %s" % (s, e)
                        except (IndexError, NameError, TypeError):
                            return ''
                        except SyntaxError,e:
                            if self.target:
                                raise SCons.Errors.BuildError, (self.target[0], "Syntax error `%s' trying to evaluate `%s'" % (e,s))
                            else:
                                raise SCons.Errors.UserError, "Syntax error `%s' trying to evaluate `%s'" % (e,s)
                    else:
                        if lvars.has_key(key):
                            s = lvars[key]
                        elif self.gvars.has_key(key):
                            s = self.gvars[key]
                        else:
                            return ''
    
                    # Before re-expanding the result, handle
                    # recursive expansion by copying the local
                    # variable dictionary and overwriting a null
                    # string for the value of the variable name
                    # we just expanded.
                    #
                    # This could potentially be optimized by only
                    # copying lvars when s contains more expansions,
                    # but lvars is usually supposed to be pretty
                    # small, and deeply nested variable expansions
                    # are probably more the exception than the norm,
                    # so it should be tolerable for now.
                    lv = lvars.copy()
                    var = string.split(key, '.')[0]
                    lv[var] = ''
                    return self.substitute(s, lv)
            elif is_List(s) or is_Tuple(s):
                def func(l, conv=self.conv, substitute=self.substitute, lvars=lvars):
                    return conv(substitute(l, lvars))
                r = map(func, s)
                return string.join(r)
            elif callable(s):
                try:
                    s = s(target=self.target,
                         source=self.source,
                         env=self.env,
                         for_signature=(self.mode != SUBST_CMD))
                except TypeError:
                    # This probably indicates that it's a callable
                    # object that doesn't match our calling arguments
                    # (like an Action).
                    s = str(s)
                return self.substitute(s, lvars)
            elif s is None:
                return ''
            else:
                return s

        def substitute(self, args, lvars):
            """Substitute expansions in an argument or list of arguments.

            This serves as a wrapper for splitting up a string into
            separate tokens.
            """
            if is_String(args) and not isinstance(args, CmdStringHolder):
                try:
                    def sub_match(match, conv=self.conv, expand=self.expand, lvars=lvars):
                        return conv(expand(match.group(1), lvars))
                    result = _dollar_exps.sub(sub_match, args)
                except TypeError:
                    # If the internal conversion routine doesn't return
                    # strings (it could be overridden to return Nodes, for
                    # example), then the 1.5.2 re module will throw this
                    # exception.  Back off to a slower, general-purpose
                    # algorithm that works for all data types.
                    args = _separate_args.findall(args)
                    result = []
                    for a in args:
                        result.append(self.conv(self.expand(a, lvars)))
                    try:
                        result = string.join(result, '')
                    except TypeError:
                        if len(result) == 1:
                            result = result[0]
                return result
            else:
                return self.expand(args, lvars)

    if conv is None:
        conv = _strconv[mode]

    # Doing this every time is a bit of a waste, since the Executor
    # has typically already populated the OverrideEnvironment with
    # $TARGET/$SOURCE variables.  We're keeping this (for now), though,
    # because it supports existing behavior that allows us to call
    # an Action directly with an arbitrary target+source pair, which
    # we use in Tool/tex.py to handle calling $BIBTEX when necessary.
    # If we dropped that behavior (or found another way to cover it),
    # we could get rid of this call completely and just rely on the
    # Executor setting the variables.
    d = subst_dict(target, source)
    if d:
        lvars = lvars.copy()
        lvars.update(d)

    # We're (most likely) going to eval() things.  If Python doesn't
    # find a __builtin__ value in the global dictionary used for eval(),
    # it copies the current __builtin__ values for you.  Avoid this by
    # setting it explicitly and then deleting, so we don't pollute the
    # construction environment Dictionary(ies) that are typically used
    # for expansion.
    gvars['__builtin__'] = __builtin__

    ss = StringSubber(env, mode, target, source, conv, gvars)
    result = ss.substitute(strSubst, lvars)

    try:
        del gvars['__builtin__']
    except KeyError:
        pass

    if is_String(result):
        # Remove $(-$) pairs and any stuff in between,
        # if that's appropriate.
        remove = _regex_remove[mode]
        if remove:
            result = remove.sub('', result)
        if mode != SUBST_RAW:
            # Compress strings of white space characters into
            # a single space.
            result = string.strip(_space_sep.sub(' ', result))

    return result

#Subst_List_Strings = {}

def scons_subst_list(strSubst, env, mode=SUBST_RAW, target=None, source=None, gvars={}, lvars={}, conv=None):
    """Substitute construction variables in a string (or list or other
    object) and separate the arguments into a command list.

    The companion scons_subst() function (above) handles basic
    substitutions within strings, so see that function instead
    if that's what you're looking for.
    """
#    try:
#        Subst_List_Strings[strSubst] = Subst_List_Strings[strSubst] + 1
#    except KeyError:
#        Subst_List_Strings[strSubst] = 1
#    import SCons.Debug
#    SCons.Debug.caller(1)
    class ListSubber(UserList.UserList):
        """A class to construct the results of a scons_subst_list() call.

        Like StringSubber, this class binds a specific construction
        environment, mode, target and source with two methods
        (substitute() and expand()) that handle the expansion.

        In addition, however, this class is used to track the state of
        the result(s) we're gathering so we can do the appropriate thing
        whenever we have to append another word to the result--start a new
        line, start a new word, append to the current word, etc.  We do
        this by setting the "append" attribute to the right method so
        that our wrapper methods only need ever call ListSubber.append(),
        and the rest of the object takes care of doing the right thing
        internally.
        """
        def __init__(self, env, mode, target, source, conv, gvars):
            UserList.UserList.__init__(self, [])
            self.env = env
            self.mode = mode
            self.target = target
            self.source = source
            self.conv = conv
            self.gvars = gvars

            if self.mode == SUBST_RAW:
                self.add_strip = lambda x, s=self: s.append(x)
            else:
                self.add_strip = lambda x, s=self: None
            self.in_strip = None
            self.next_line()

        def expand(self, s, lvars, within_list):
            """Expand a single "token" as necessary, appending the
            expansion to the current result.

            This handles expanding different types of things (strings,
            lists, callables) appropriately.  It calls the wrapper
            substitute() method to re-expand things as necessary, so that
            the results of expansions of side-by-side strings still get
            re-evaluated separately, not smushed together.
            """

            if is_String(s):
                try:
                    s0, s1 = s[:2]
                except (IndexError, ValueError):
                    self.append(s)
                    return
                if s0 != '$':
                    self.append(s)
                    return
                if s1 == '$':
                    self.append('$')
                elif s1 == '(':
                    self.open_strip('$(')
                elif s1 == ')':
                    self.close_strip('$)')
                else:
                    key = s[1:]
                    if key[0] == '{' or string.find(key, '.') >= 0:
                        if key[0] == '{':
                            key = key[1:-1]
                        try:
                            s = eval(key, self.gvars, lvars)
                        except AttributeError, e:
                            raise SCons.Errors.UserError, \
                                  "Error trying to evaluate `%s': %s" % (s, e)
                        except (IndexError, NameError, TypeError):
                            return
                        except SyntaxError,e:
                            if self.target:
                                raise SCons.Errors.BuildError, (self.target[0], "Syntax error `%s' trying to evaluate `%s'" % (e,s))
                            else:
                                raise SCons.Errors.UserError, "Syntax error `%s' trying to evaluate `%s'" % (e,s)
                    else:
                        if lvars.has_key(key):
                            s = lvars[key]
                        elif self.gvars.has_key(key):
                            s = self.gvars[key]
                        else:
                            return

                    # Before re-expanding the result, handle
                    # recursive expansion by copying the local
                    # variable dictionary and overwriting a null
                    # string for the value of the variable name
                    # we just expanded.
                    lv = lvars.copy()
                    var = string.split(key, '.')[0]
                    lv[var] = ''
                    self.substitute(s, lv, 0)
                    self.this_word()
            elif is_List(s) or is_Tuple(s):
                for a in s:
                    self.substitute(a, lvars, 1)
                    self.next_word()
            elif callable(s):
                try:
                    s = s(target=self.target,
                         source=self.source,
                         env=self.env,
                         for_signature=(self.mode != SUBST_CMD))
                except TypeError:
                    # This probably indicates that it's a callable
                    # object that doesn't match our calling arguments
                    # (like an Action).
                    s = str(s)
                self.substitute(s, lvars, within_list)
            elif s is None:
                self.this_word()
            else:
                self.append(s)

        def substitute(self, args, lvars, within_list):
            """Substitute expansions in an argument or list of arguments.

            This serves as a wrapper for splitting up a string into
            separate tokens.
            """

            if is_String(args) and not isinstance(args, CmdStringHolder):
                args = _separate_args.findall(args)
                for a in args:
                    if a[0] in ' \t\n\r\f\v':
                        if '\n' in a:
                            self.next_line()
                        elif within_list:
                            self.append(a)
                        else:
                            self.next_word()
                    else:
                        self.expand(a, lvars, within_list)
            else:
                self.expand(args, lvars, within_list)

        def next_line(self):
            """Arrange for the next word to start a new line.  This
            is like starting a new word, except that we have to append
            another line to the result."""
            UserList.UserList.append(self, [])
            self.next_word()

        def this_word(self):
            """Arrange for the next word to append to the end of the
            current last word in the result."""
            self.append = self.add_to_current_word

        def next_word(self):
            """Arrange for the next word to start a new word."""
            self.append = self.add_new_word

        def add_to_current_word(self, x):
            """Append the string x to the end of the current last word
            in the result.  If that is not possible, then just add
            it as a new word.  Make sure the entire concatenated string
            inherits the object attributes of x (in particular, the
            escape function) by wrapping it as CmdStringHolder."""

            if not self.in_strip or self.mode != SUBST_SIG:
                try:
                    current_word = self[-1][-1]
                except IndexError:
                    self.add_new_word(x)
                else:
                    # All right, this is a hack and it should probably
                    # be refactored out of existence in the future.
                    # The issue is that we want to smoosh words together
                    # and make one file name that gets escaped if
                    # we're expanding something like foo$EXTENSION,
                    # but we don't want to smoosh them together if
                    # it's something like >$TARGET, because then we'll
                    # treat the '>' like it's part of the file name.
                    # So for now, just hard-code looking for the special
                    # command-line redirection characters...
                    try:
                        last_char = str(current_word)[-1]
                    except IndexError:
                        last_char = '\0'
                    if last_char in '<>|':
                        self.add_new_word(x)
                    else:
                        y = current_word + x

                        # We used to treat a word appended to a literal
                        # as a literal itself, but this caused problems
                        # with interpreting quotes around space-separated
                        # targets on command lines.  Removing this makes
                        # none of the "substantive" end-to-end tests fail,
                        # so we'll take this out but leave it commented
                        # for now in case there's a problem not covered
                        # by the test cases and we need to resurrect this.
                        #literal1 = self.literal(self[-1][-1])
                        #literal2 = self.literal(x)
                        y = self.conv(y)
                        if is_String(y):
                            #y = CmdStringHolder(y, literal1 or literal2)
                            y = CmdStringHolder(y, None)
                        self[-1][-1] = y

        def add_new_word(self, x):
            if not self.in_strip or self.mode != SUBST_SIG:
                literal = self.literal(x)
                x = self.conv(x)
                if is_String(x):
                    x = CmdStringHolder(x, literal)
                self[-1].append(x)
            self.append = self.add_to_current_word

        def literal(self, x):
            try:
                l = x.is_literal
            except AttributeError:
                return None
            else:
                return l()

        def open_strip(self, x):
            """Handle the "open strip" $( token."""
            self.add_strip(x)
            self.in_strip = 1

        def close_strip(self, x):
            """Handle the "close strip" $) token."""
            self.add_strip(x)
            self.in_strip = None

    if conv is None:
        conv = _strconv[mode]

    # Doing this every time is a bit of a waste, since the Executor
    # has typically already populated the OverrideEnvironment with
    # $TARGET/$SOURCE variables.  We're keeping this (for now), though,
    # because it supports existing behavior that allows us to call
    # an Action directly with an arbitrary target+source pair, which
    # we use in Tool/tex.py to handle calling $BIBTEX when necessary.
    # If we dropped that behavior (or found another way to cover it),
    # we could get rid of this call completely and just rely on the
    # Executor setting the variables.
    d = subst_dict(target, source)
    if d:
        lvars = lvars.copy()
        lvars.update(d)

    # We're (most likely) going to eval() things.  If Python doesn't
    # find a __builtin__ value in the global dictionary used for eval(),
    # it copies the current __builtin__ values for you.  Avoid this by
    # setting it explicitly and then deleting, so we don't pollute the
    # construction environment Dictionary(ies) that are typically used
    # for expansion.
    gvars['__builtins__'] = __builtins__

    ls = ListSubber(env, mode, target, source, conv, gvars)
    ls.substitute(strSubst, lvars, 0)

    try:
        del gvars['__builtins__']
    except KeyError:
        pass

    return ls.data

def scons_subst_once(strSubst, env, key):
    """Perform single (non-recursive) substitution of a single
    construction variable keyword.

    This is used when setting a variable when copying or overriding values
    in an Environment.  We want to capture (expand) the old value before
    we override it, so people can do things like:

        env2 = env.Clone(CCFLAGS = '$CCFLAGS -g')

    We do this with some straightforward, brute-force code here...
    """
    if type(strSubst) == types.StringType and string.find(strSubst, '$') < 0:
        return strSubst

    matchlist = ['$' + key, '${' + key + '}']
    val = env.get(key, '')
    def sub_match(match, val=val, matchlist=matchlist):
        a = match.group(1)
        if a in matchlist:
            a = val
        if is_List(a) or is_Tuple(a):
            return string.join(map(str, a))
        else:
            return str(a)

    if is_List(strSubst) or is_Tuple(strSubst):
        result = []
        for arg in strSubst:
            if is_String(arg):
                if arg in matchlist:
                    arg = val
                    if is_List(arg) or is_Tuple(arg):
                        result.extend(arg)
                    else:
                        result.append(arg)
                else:
                    result.append(_dollar_exps.sub(sub_match, arg))
            else:
                result.append(arg)
        return result
    elif is_String(strSubst):
        return _dollar_exps.sub(sub_match, strSubst)
    else:
        return strSubst
