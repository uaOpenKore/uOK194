"""SCons.Scanner.LaTeX

This module implements the dependency scanner for LaTeX code.

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

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/Scanner/LaTeX.py 0.96.93.D001 2006/11/06 08:31:54 knight"


import SCons.Scanner

def LaTeXScanner(fs = SCons.Node.FS.default_fs):
    """Return a prototype Scanner instance for scanning LaTeX source files"""
    ds = LaTeX(name = "LaTeXScanner",
               suffixes =  '$LATEXSUFFIXES',
               path_variable = 'TEXINPUTS',
               regex = '\\\\(include|includegraphics(?:\[[^\]]+\])?|input){([^}]*)}',
               recursive = 0)
    return ds

class LaTeX(SCons.Scanner.Classic):
    """Class for scanning LaTeX files for included files.

    Unlike most scanners, which use regular expressions that just
    return the included file name, this returns a tuple consisting
    of the keyword for the inclusion ("include", "includegraphics" or
    "input"), and then the file name itself.  Base on a quick look at
    LaTeX documentation, it seems that we need a should append .tex
    suffix for "include" and "input" keywords, but leave the file name
    untouched for "includegraphics."
    """
    def latex_name(self, include):
        filename = include[1]
        if include[0][:15] != 'includegraphics':
            filename = filename + '.tex'
        return filename
    def sort_key(self, include):
        return SCons.Node.FS._my_normcase(self.latex_name(include))
    def find_include(self, include, source_dir, path):
        if callable(path): path=path()
        i = SCons.Node.FS.find_file(self.latex_name(include),
                                    (source_dir,) + path)
        return i, include
