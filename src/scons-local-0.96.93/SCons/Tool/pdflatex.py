"""SCons.Tool.pdflatex

Tool-specific initialization for pdflatex.

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

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/Tool/pdflatex.py 0.96.93.D001 2006/11/06 08:31:54 knight"

import SCons.Action
import SCons.Util
import SCons.Tool.pdf
import SCons.Tool.tex

PDFLaTeXAction = None

def PDFLaTeXAuxFunction(target = None, source= None, env=None):
    SCons.Tool.tex.InternalLaTeXAuxAction( PDFLaTeXAction, target, source, env )

PDFLaTeXAuxAction = None

def generate(env):
    """Add Builders and construction variables for pdflatex to an Environment."""
    global PDFLaTeXAction
    if PDFLaTeXAction is None:
        PDFLaTeXAction = SCons.Action.Action('$PDFLATEXCOM', '$PDFLATEXCOMSTR')

    global PDFLaTeXAuxAction
    if PDFLaTeXAuxAction is None:
        PDFLaTeXAuxAction = SCons.Action.Action(PDFLaTeXAuxFunction,
                                                strfunction=None)

    import pdf
    pdf.generate(env)

    bld = env['BUILDERS']['PDF']
    bld.add_action('.ltx', PDFLaTeXAuxAction)
    bld.add_action('.latex', PDFLaTeXAuxAction)
    bld.add_emitter('.ltx', SCons.Tool.tex.tex_emitter)
    bld.add_emitter('.latex', SCons.Tool.tex.tex_emitter)

    env['PDFLATEX']      = 'pdflatex'
    env['PDFLATEXFLAGS'] = SCons.Util.CLVar('')
    env['PDFLATEXCOM']   = '$PDFLATEX $PDFLATEXFLAGS $SOURCE'
    env['LATEXRETRIES']  = 3

def exists(env):
    return env.Detect('pdflatex')
