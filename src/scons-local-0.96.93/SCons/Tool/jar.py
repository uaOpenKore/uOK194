"""SCons.Tool.jar

Tool-specific initialization for jar.

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

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/Tool/jar.py 0.96.93.D001 2006/11/06 08:31:54 knight"

import SCons.Action
import SCons.Builder
import SCons.Util

def jarSources(target, source, env, for_signature):
    """Only include sources that are not a manifest file."""
    jarchdir = env.subst('$JARCHDIR')
    result = []
    for src in source:
        contents = src.get_contents()
        if contents[:16] != "Manifest-Version":
            if jarchdir:
                # If we are changing the dir with -C, then sources should
                # be relative to that directory.
                src = src.get_path(src.fs.Dir(jarchdir))
                result.append('-C')
                result.append(jarchdir)
            result.append(src)
    return result

def jarManifest(target, source, env, for_signature):
    """Look in sources for a manifest file, if any."""
    for src in source:
        contents = src.get_contents()
        if contents[:16] == "Manifest-Version":
            return src
    return ''

def jarFlags(target, source, env, for_signature):
    """If we have a manifest, make sure that the 'm'
    flag is specified."""
    jarflags = env.subst('$JARFLAGS')
    for src in source:
        contents = src.get_contents()
        if contents[:16] == "Manifest-Version":
            if not 'm' in jarflags:
                return jarflags + 'm'
            break
    return jarflags

JarAction = SCons.Action.Action('$JARCOM', '$JARCOMSTR')

JarBuilder = SCons.Builder.Builder(action = JarAction,
                                   source_factory = SCons.Node.FS.Entry,
                                   suffix = '$JARSUFFIX')

def generate(env):
    """Add Builders and construction variables for jar to an Environment."""
    try:
        env['BUILDERS']['Jar']
    except KeyError:
        env['BUILDERS']['Jar'] = JarBuilder

    env['JAR']        = 'jar'
    env['JARFLAGS']   = SCons.Util.CLVar('cf')
    env['_JARFLAGS']  = jarFlags
    env['_JARMANIFEST'] = jarManifest
    env['_JARSOURCES'] = jarSources
    env['JARCOM']     = '$JAR $_JARFLAGS $TARGET $_JARMANIFEST $_JARSOURCES'
    env['JARSUFFIX']  = '.jar'

def exists(env):
    return env.Detect('jar')
