"""SCons.Tool.javah

Tool-specific initialization for javah.

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

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/Tool/javah.py 0.96.93.D001 2006/11/06 08:31:54 knight"

import os.path
import string

import SCons.Action
import SCons.Builder
import SCons.Node.FS
import SCons.Tool.javac
import SCons.Util

def emit_java_headers(target, source, env):
    """Create and return lists of Java stub header files that will
    be created from a set of class files.
    """
    class_suffix = env.get('JAVACLASSSUFFIX', '.class')
    classdir = env.get('JAVACLASSDIR')

    if not classdir:
        try:
            s = source[0]
        except IndexError:
            classdir = '.'
        else:
            try:
                classdir = s.attributes.java_classdir
            except AttributeError:
                classdir = '.'
    classdir = env.Dir(classdir).rdir()
    if str(classdir) == '.':
        c_ = None
    else:
        c_ = str(classdir) + os.sep

    slist = []
    for src in source:
        try:
            classname = src.attributes.java_classname
        except AttributeError:
            classname = str(src)
            if c_ and classname[:len(c_)] == c_:
                classname = classname[len(c_):]
            if class_suffix and classname[-len(class_suffix):] == class_suffix:
                classname = classname[:-len(class_suffix)]
            classname = SCons.Tool.javac.classname(classname)
        s = src.rfile()
        s.attributes.java_classdir = classdir
        s.attributes.java_classname = classname
        slist.append(s)

    if target[0].__class__ is SCons.Node.FS.File:
        tlist = target
    else:
        if not isinstance(target[0], SCons.Node.FS.Dir):
            target[0].__class__ = SCons.Node.FS.Dir
            target[0]._morph()
        tlist = []
        for s in source:
            fname = string.replace(s.attributes.java_classname, '.', '_') + '.h'
            t = target[0].File(fname)
            t.attributes.java_lookupdir = target[0]
            tlist.append(t)

    return tlist, source

def JavaHOutFlagGenerator(target, source, env, for_signature):
    try:
        t = target[0]
    except (AttributeError, TypeError):
        t = target
    try:
        return '-d ' + str(t.attributes.java_lookupdir)
    except AttributeError:
        return '-o ' + str(t)

JavaHAction = SCons.Action.Action('$JAVAHCOM', '$JAVAHCOMSTR')

JavaHBuilder = SCons.Builder.Builder(action = JavaHAction,
                     emitter = emit_java_headers,
                     src_suffix = '$JAVACLASSSUFFIX',
                     target_factory = SCons.Node.FS.Entry,
                     source_factory = SCons.Node.FS.File)

def generate(env):
    """Add Builders and construction variables for javah to an Environment."""
    env['BUILDERS']['JavaH'] = JavaHBuilder

    env['_JAVAHOUTFLAG']    = JavaHOutFlagGenerator
    env['JAVAH']            = 'javah'
    env['JAVAHFLAGS']       = SCons.Util.CLVar('')
    env['JAVAHCOM']         = '$JAVAH $JAVAHFLAGS $_JAVAHOUTFLAG -classpath ${SOURCE.attributes.java_classdir} ${SOURCES.attributes.java_classname}'
    env['JAVACLASSSUFFIX']  = '.class'

def exists(env):
    return env.Detect('javah')
