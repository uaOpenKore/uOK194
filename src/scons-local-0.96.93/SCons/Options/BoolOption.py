"""engine.SCons.Options.BoolOption

This file defines the option type for SCons implementing true/false values.

Usage example:

  opts = Options()
  opts.Add(BoolOption('embedded', 'build for an embedded system', 0))
  ...
  if env['embedded'] == 1:
    ...
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

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/Options/BoolOption.py 0.96.93.D001 2006/11/06 08:31:54 knight"

__all__ = ('BoolOption', 'True', 'False')

import string

import SCons.Errors

__true_strings  = ('y', 'yes', 'true', 't', '1', 'on' , 'all' )
__false_strings = ('n', 'no', 'false', 'f', '0', 'off', 'none')

# we need this since SCons should work version indepentant
True, False = 1, 0


def _text2bool(val):
    """
    Converts strings to True/False depending on the 'truth' expressed by
    the string. If the string can't be converted, the original value
    will be returned.

    See '__true_strings' and '__false_strings' for values considered
    'true' or 'false respectivly.

    This is usable as 'converter' for SCons' Options.
    """
    lval = string.lower(val)
    if lval in __true_strings: return True
    if lval in __false_strings: return False
    raise ValueError("Invalid value for boolean option: %s" % val)


def _validator(key, val, env):
    """
    Validates the given value to be either '0' or '1'.
    
    This is usable as 'validator' for SCons' Options.
    """
    if not env[key] in (True, False):
        raise SCons.Errors.UserError(
            'Invalid value for boolean option %s: %s' % (key, env[key]))


def BoolOption(key, help, default):
    """
    The input parameters describe a boolen option, thus they are
    returned with the correct converter and validator appended. The
    'help' text will by appended by '(yes|no) to show the valid
    valued. The result is usable for input to opts.Add().
    """
    return (key, '%s (yes|no)' % help, default,
            _validator, _text2bool)
