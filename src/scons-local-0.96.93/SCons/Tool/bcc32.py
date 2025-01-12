"""SCons.Tool.bcc32

XXX

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

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/Tool/bcc32.py 0.96.93.D001 2006/11/06 08:31:54 knight"

import os
import os.path
import string

import SCons.Defaults
import SCons.Tool
import SCons.Util

def findIt(program, env):
    # First search in the SCons path and then the OS path:
    borwin = env.WhereIs(program) or SCons.Util.WhereIs(program)
    if borwin:
        dir = os.path.dirname(borwin)
        path = env['ENV'].get('PATH', [])
        if not path:
            path = []
        if SCons.Util.is_String(path):
            path = string.split(path, os.pathsep)
        env['ENV']['PATH'] = string.join([dir]+path, os.pathsep)
    return borwin

def generate(env):
    findIt('bcc32', env)
    """Add Builders and construction variables for bcc to an
    Environment."""
    static_obj, shared_obj = SCons.Tool.createObjBuilders(env)
    for suffix in ['.c', '.cpp']:
        static_obj.add_action(suffix, SCons.Defaults.CAction)
        shared_obj.add_action(suffix, SCons.Defaults.ShCAction)
        static_obj.add_emitter(suffix, SCons.Defaults.StaticObjectEmitter)
        shared_obj.add_emitter(suffix, SCons.Defaults.SharedObjectEmitter)

    env['CC']        = 'bcc32'
    env['CCFLAGS']   = SCons.Util.CLVar('')
    env['CCCOM']     = '$CC -q $CCFLAGS $CPPFLAGS $_CPPDEFFLAGS $_CPPINCFLAGS -c -o$TARGET $SOURCES'
    env['SHCC']      = '$CC'
    env['SHCCFLAGS'] = SCons.Util.CLVar('$CCFLAGS')
    env['SHCCCOM']   = '$SHCC -WD $SHCCFLAGS $CPPFLAGS $_CPPDEFFLAGS $_CPPINCFLAGS -c -o$TARGET $SOURCES'
    env['CPPDEFPREFIX']  = '-D'
    env['CPPDEFSUFFIX']  = ''
    env['INCPREFIX']  = '-I'
    env['INCSUFFIX']  = ''
    env['SHOBJSUFFIX'] = '.dll'
    env['STATIC_AND_SHARED_OBJECTS_ARE_THE_SAME'] = 0
    env['CFILESUFFIX'] = '.cpp'

def exists(env):
    return findIt('bcc32', env)
