"""SCons.Tool.sgiar

Tool-specific initialization for SGI ar (library archive).  If CC
exists, static libraries should be built with it, so the prelinker has
a chance to resolve C++ template instantiations.

There normally shouldn't be any need to import this module directly.
It will usually be imported through the generic SCons.Tool.Tool()
selection method.

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

__revision__ = "/home/scons/scons/branch.0/baseline/src/engine/SCons/Tool/sgiar.py 0.96.93.D001 2006/11/06 08:31:54 knight"

import SCons.Defaults
import SCons.Tool
import SCons.Util

def generate(env):
    """Add Builders and construction variables for ar to an Environment."""
    SCons.Tool.createStaticLibBuilder(env)
    
    if env.Detect('CC'):
        env['AR']          = 'CC'
        env['ARFLAGS']     = SCons.Util.CLVar('-ar')
        env['ARCOM']       = '$AR $ARFLAGS -o $TARGET $SOURCES'
    else:
        env['AR']          = 'ar'
        env['ARFLAGS']     = SCons.Util.CLVar('r')
        env['ARCOM']       = '$AR $ARFLAGS $TARGET $SOURCES'
        
    env['SHLINK']      = '$LINK'
    env['SHLINKFLAGS'] = SCons.Util.CLVar('$LINKFLAGS -shared')
    env['SHLINKCOM']   = '$SHLINK $SHLINKFLAGS -o $TARGET $SOURCES $_LIBDIRFLAGS $_LIBFLAGS'
    env['LIBPREFIX']   = 'lib'
    env['LIBSUFFIX']   = '.a'

def exists(env):
    return env.Detect('CC') or env.Detect('ar')
