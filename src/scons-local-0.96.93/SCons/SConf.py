"""SCons.SConf

Autoconf-like configuration support.
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

__revision__ = "/home/scons/scons/branch.0/branch.96/baseline/src/engine/SCons/SConf.py 0.96.93.D001 2006/11/06 08:31:54 knight"

import os
import re
import string
import StringIO
import sys
import traceback
import types

import SCons.Action
import SCons.Builder
import SCons.Errors
import SCons.Node.FS
import SCons.Taskmaster
import SCons.Util
import SCons.Warnings
import SCons.Conftest

# Turn off the Conftest error logging
SCons.Conftest.LogInputFiles = 0
SCons.Conftest.LogErrorMessages = 0

# to be set, if we are in dry-run mode
dryrun = 0

AUTO=0  # use SCons dependency scanning for up-to-date checks
FORCE=1 # force all tests to be rebuilt
CACHE=2 # force all tests to be taken from cache (raise an error, if necessary)
cache_mode = AUTO

def SetCacheMode(mode):
    """Set the Configure cache mode. mode must be one of "auto", "force",
    or "cache"."""
    global cache_mode
    if mode == "auto":
        cache_mode = AUTO
    elif mode == "force":
        cache_mode = FORCE
    elif mode == "cache":
        cache_mode = CACHE
    else:
        raise ValueError, "SCons.SConf.SetCacheMode: Unknown mode " + mode

progress_display = SCons.Util.display # will be overwritten by SCons.Script
def SetProgressDisplay(display):
    """Set the progress display to use (called from SCons.Script)"""
    global progress_display
    progress_display = display

SConfFS = None

_ac_build_counter = 0 # incremented, whenever TryBuild is called
_ac_config_logs = {}  # all config.log files created in this build
_ac_config_hs   = {}  # all config.h files created in this build
sconf_global = None   # current sconf object

def _createConfigH(target, source, env):
    t = open(str(target[0]), "w")
    defname = re.sub('[^A-Za-z0-9_]', '_', string.upper(str(target[0])))
    t.write("""#ifndef %(DEFNAME)s_SEEN
#define %(DEFNAME)s_SEEN

""" % {'DEFNAME' : defname})
    t.write(source[0].get_contents())
    t.write("""
#endif /* %(DEFNAME)s_SEEN */
""" % {'DEFNAME' : defname})
    t.close()

def _stringConfigH(target, source, env):
    return "scons: Configure: creating " + str(target[0])

def CreateConfigHBuilder(env):
    """Called just before the building targets phase begins."""
    if len(_ac_config_hs) == 0:
        return
    action = SCons.Action.Action(_createConfigH,
                                 _stringConfigH)
    sconfigHBld = SCons.Builder.Builder(action=action)
    env.Append( BUILDERS={'SConfigHBuilder':sconfigHBld} )
    for k in _ac_config_hs.keys():
        env.SConfigHBuilder(k, env.Value(_ac_config_hs[k]))
    
class SConfWarning(SCons.Warnings.Warning):
    pass
SCons.Warnings.enableWarningClass(SConfWarning)

# some error definitions
class SConfError(SCons.Errors.UserError):
    def __init__(self,msg):
        SCons.Errors.UserError.__init__(self,msg)

class ConfigureDryRunError(SConfError):
    """Raised when a file or directory needs to be updated during a Configure
    process, but the user requested a dry-run"""
    def __init__(self,target):
        if not isinstance(target, SCons.Node.FS.File):
            msg = 'Cannot create configure directory "%s" within a dry-run.' % str(target)
        else:
            msg = 'Cannot update configure test "%s" within a dry-run.' % str(target)
        SConfError.__init__(self,msg)

class ConfigureCacheError(SConfError):
    """Raised when a use explicitely requested the cache feature, but the test
    is run the first time."""
    def __init__(self,target):
        SConfError.__init__(self, '"%s" is not yet built and cache is forced.' % str(target))

# define actions for building text files
def _createSource( target, source, env ):
    fd = open(str(target[0]), "w")
    fd.write(source[0].get_contents())
    fd.close()
def _stringSource( target, source, env ):
    import string
    return (str(target[0]) + ' <-\n  |' +
            string.replace( source[0].get_contents(),
                            '\n', "\n  |" ) )

# python 2.2 introduces types.BooleanType
BooleanTypes = [types.IntType]
if hasattr(types, 'BooleanType'): BooleanTypes.append(types.BooleanType)

class SConfBuildInfo(SCons.Node.FS.FileBuildInfo):
    """
    Special build info for targets of configure tests. Additional members
    are result (did the builder succeed last time?) and string, which
    contains messages of the original build phase.
    """
    result = None # -> 0/None -> no error, != 0 error
    string = None # the stdout / stderr output when building the target
    
    def __init__(self, node, result, string, sig):
        SCons.Node.FS.FileBuildInfo.__init__(self, node)
        self.result = result
        self.string = string
        self.ninfo.bsig = sig


class Streamer:
    """
    'Sniffer' for a file-like writable object. Similar to the unix tool tee.
    """
    def __init__(self, orig):
        self.orig = orig
        self.s = StringIO.StringIO()

    def write(self, str):
        if self.orig:
            self.orig.write(str)
        self.s.write(str)

    def writelines(self, lines):
        for l in lines:
            self.write(l + '\n')

    def getvalue(self):
        """
        Return everything written to orig since the Streamer was created.
        """
        return self.s.getvalue()
        

class SConfBuildTask(SCons.Taskmaster.Task):
    """
    This is almost the same as SCons.Script.BuildTask. Handles SConfErrors
    correctly and knows about the current cache_mode.
    """
    def display(self, message):
        if sconf_global.logstream:
            sconf_global.logstream.write("scons: Configure: " + message + "\n")

    def display_cached_string(self, bi):
        """
        Logs the original builder messages, given the SConfBuildInfo instance
        bi.
        """
        if not isinstance(bi, SConfBuildInfo):
            SCons.Warnings.warn(SConfWarning,
              "The stored build information has an unexpected class.")
        else:
            self.display("The original builder output was:\n" +
                         string.replace("  |" + str(bi.string),
                                        "\n", "\n  |"))

    def failed(self):
        # check, if the reason was a ConfigureDryRunError or a
        # ConfigureCacheError and if yes, reraise the exception
        exc_type = self.exc_info()[0]
        if issubclass(exc_type, SConfError):
            raise
        elif issubclass(exc_type, SCons.Errors.BuildError):
            # we ignore Build Errors (occurs, when a test doesn't pass)
            pass
        else:
            self.display('Caught exception while building "%s":\n' %
                         self.targets[0])
            try:
                excepthook = sys.excepthook
            except AttributeError:
                # Earlier versions of Python don't have sys.excepthook...
                def excepthook(type, value, tb):
                    import traceback
                    traceback.print_tb(tb)
                    print type, value
            apply(excepthook, self.exc_info())
        return SCons.Taskmaster.Task.failed(self)

    def collect_node_states(self):
        # returns (is_up_to_date, cached_error, cachable)
        # where is_up_to_date is 1, if the node(s) are up_to_date
        #       cached_error  is 1, if the node(s) are up_to_date, but the
        #                           build will fail
        #       cachable      is 0, if some nodes are not in our cache
        is_up_to_date = 1
        cached_error = 0
        cachable = 1
        for t in self.targets:
            bi = t.get_stored_info()
            if isinstance(bi, SConfBuildInfo):
                if cache_mode == CACHE:
                    t.set_state(SCons.Node.up_to_date)
                else:
                    new_bsig = t.calc_signature(sconf_global.calc)
                    if t.env.use_build_signature():
                        old_bsig = bi.ninfo.bsig
                    else:
                        old_bsig = bi.ninfo.csig
                    is_up_to_date = (is_up_to_date and new_bsig == old_bsig)
                cached_error = cached_error or bi.result
            else:
                # the node hasn't been built in a SConf context or doesn't
                # exist
                cachable = 0
                is_up_to_date = 0
        return (is_up_to_date, cached_error, cachable)

    def execute(self):
        sconf = sconf_global

        is_up_to_date, cached_error, cachable = self.collect_node_states()

        if cache_mode == CACHE and not cachable:
            raise ConfigureCacheError(self.targets[0])
        elif cache_mode == FORCE:
            is_up_to_date = 0

        if cached_error and is_up_to_date:
            self.display("Building \"%s\" failed in a previous run and all "
                         "its sources are up to date." % str(self.targets[0]))
            self.display_cached_string(self.targets[0].get_stored_info())
            raise SCons.Errors.BuildError # will be 'caught' in self.failed
        elif is_up_to_date:            
            self.display("\"%s\" is up to date." % str(self.targets[0]))
            self.display_cached_string(self.targets[0].get_stored_info())
        elif dryrun:
            raise ConfigureDryRunError(self.targets[0])
        else:
            # note stdout and stderr are the same here
            s = sys.stdout = sys.stderr = Streamer(sys.stdout)
            try:
                env = self.targets[0].get_build_env()
                env['PSTDOUT'] = env['PSTDERR'] = s
                try:
                    sconf.cached = 0
                    self.targets[0].build()
                finally:
                    sys.stdout = sys.stderr = env['PSTDOUT'] = \
                                 env['PSTDERR'] = sconf.logstream
            except KeyboardInterrupt:
                raise
            except SystemExit:
                exc_value = sys.exc_info()[1]
                raise SCons.Errors.ExplicitExit(self.targets[0],exc_value.code)
            except:
                for t in self.targets:
                    sig = t.calc_signature(sconf.calc)
                    string = s.getvalue()
                    binfo = SConfBuildInfo(t,1,string,sig)
                    t.dir.sconsign().set_entry(t.name, binfo)
                raise
            else:
                for t in self.targets:
                    sig = t.calc_signature(sconf.calc)
                    string = s.getvalue()
                    binfo = SConfBuildInfo(t,0,string,sig)
                    t.dir.sconsign().set_entry(t.name, binfo)

class SConf:
    """This is simply a class to represent a configure context. After
    creating a SConf object, you can call any tests. After finished with your
    tests, be sure to call the Finish() method, which returns the modified
    environment.
    Some words about caching: In most cases, it is not necessary to cache
    Test results explicitely. Instead, we use the scons dependency checking
    mechanism. For example, if one wants to compile a test program
    (SConf.TryLink), the compiler is only called, if the program dependencies
    have changed. However, if the program could not be compiled in a former
    SConf run, we need to explicitely cache this error.
    """

    def __init__(self, env, custom_tests = {}, conf_dir='$CONFIGUREDIR',
                 log_file='$CONFIGURELOG', config_h = None, _depth = 0): 
        """Constructor. Pass additional tests in the custom_tests-dictinary,
        e.g. custom_tests={'CheckPrivate':MyPrivateTest}, where MyPrivateTest
        defines a custom test.
        Note also the conf_dir and log_file arguments (you may want to
        build tests in the BuildDir, not in the SourceDir)
        """
        global SConfFS
        if not SConfFS:
            SConfFS = SCons.Node.FS.default_fs or \
                      SCons.Node.FS.FS(env.fs.pathTop)
        if not sconf_global is None:
            raise (SCons.Errors.UserError,
                   "Only one SConf object may be active at one time")
        self.env = env
        if log_file != None:
            log_file = SConfFS.File(env.subst(log_file))
        self.logfile = log_file
        self.logstream = None
        self.lastTarget = None
        self.depth = _depth
        self.cached = 0 # will be set, if all test results are cached

        # add default tests
        default_tests = {
                 'CheckFunc'          : CheckFunc,
                 'CheckType'          : CheckType,
                 'CheckHeader'        : CheckHeader,
                 'CheckCHeader'       : CheckCHeader,
                 'CheckCXXHeader'     : CheckCXXHeader,
                 'CheckLib'           : CheckLib,
                 'CheckLibWithHeader' : CheckLibWithHeader
               }
        self.AddTests(default_tests)
        self.AddTests(custom_tests)
        self.confdir = SConfFS.Dir(env.subst(conf_dir))
        self.calc = None
        if not config_h is None:
            config_h = SConfFS.File(config_h)
        self.config_h = config_h
        self._startup()

    def Finish(self):
        """Call this method after finished with your tests:
        env = sconf.Finish()"""
        self._shutdown()
        return self.env

    def BuildNodes(self, nodes):
        """
        Tries to build the given nodes immediately. Returns 1 on success,
        0 on error.
        """
        if self.logstream != None:
            # override stdout / stderr to write in log file
            oldStdout = sys.stdout
            sys.stdout = self.logstream
            oldStderr = sys.stderr
            sys.stderr = self.logstream

        # the engine assumes the current path is the SConstruct directory ...
        old_fs_dir = SConfFS.getcwd()
        old_os_dir = os.getcwd()
        SConfFS.chdir(SConfFS.Top, change_os_dir=1)

        ret = 1

        try:
            # ToDo: use user options for calc
            save_max_drift = SConfFS.get_max_drift()
            SConfFS.set_max_drift(0)
            tm = SCons.Taskmaster.Taskmaster(nodes, SConfBuildTask)
            # we don't want to build tests in parallel
            jobs = SCons.Job.Jobs(1, tm )
            jobs.run()
            for n in nodes:
                state = n.get_state()
                if (state != SCons.Node.executed and
                    state != SCons.Node.up_to_date):
                    # the node could not be built. we return 0 in this case
                    ret = 0
        finally:
            SConfFS.set_max_drift(save_max_drift)
            os.chdir(old_os_dir)
            SConfFS.chdir(old_fs_dir, change_os_dir=0)
            if self.logstream != None:
                # restore stdout / stderr
                sys.stdout = oldStdout
                sys.stderr = oldStderr
        return ret

    def pspawn_wrapper(self, sh, escape, cmd, args, env):
        """Wrapper function for handling piped spawns.

        This looks to the calling interface (in Action.py) like a "normal"
        spawn, but associates the call with the PSPAWN variable from
        the construction environment and with the streams to which we
        want the output logged.  This gets slid into the construction
        environment as the SPAWN variable so Action.py doesn't have to
        know or care whether it's spawning a piped command or not.
        """
        return self.pspawn(sh, escape, cmd, args, env, self.logstream, self.logstream)


    def TryBuild(self, builder, text = None, extension = ""):
        """Low level TryBuild implementation. Normally you don't need to
        call that - you can use TryCompile / TryLink / TryRun instead
        """
        global _ac_build_counter

        # Make sure we have a PSPAWN value, and save the current
        # SPAWN value.
        try:
            self.pspawn = self.env['PSPAWN']
        except KeyError:
            raise SCons.Errors.UserError('Missing PSPAWN construction variable.')
        try:
            save_spawn = self.env['SPAWN']
        except KeyError:
            raise SCons.Errors.UserError('Missing SPAWN construction variable.')

        nodesToBeBuilt = []

        f = "conftest_" + str(_ac_build_counter)
        pref = self.env.subst( builder.builder.prefix )
        suff = self.env.subst( builder.builder.suffix )
        target = self.confdir.File(pref + f + suff)

        try:
            # Slide our wrapper into the construction environment as
            # the SPAWN function.
            self.env['SPAWN'] = self.pspawn_wrapper
            sourcetext = self.env.Value(text)

            if text != None:
                textFile = self.confdir.File(f + extension)
                textFileNode = self.env.SConfSourceBuilder(target=textFile,
                                                           source=sourcetext)
                nodesToBeBuilt.extend(textFileNode)
                source = textFileNode
            else:
                source = None

            nodes = builder(target = target, source = source)
            if not SCons.Util.is_List(nodes):
                nodes = [nodes]
            nodesToBeBuilt.extend(nodes)
            result = self.BuildNodes(nodesToBeBuilt)

        finally:
            self.env['SPAWN'] = save_spawn

        _ac_build_counter = _ac_build_counter + 1
        if result:
            self.lastTarget = nodes[0]
        else:
            self.lastTarget = None

        return result

    def TryAction(self, action, text = None, extension = ""):
        """Tries to execute the given action with optional source file
        contents <text> and optional source file extension <extension>,
        Returns the status (0 : failed, 1 : ok) and the contents of the
        output file.
        """
        builder = SCons.Builder.Builder(action=action)
        self.env.Append( BUILDERS = {'SConfActionBuilder' : builder} )
        ok = self.TryBuild(self.env.SConfActionBuilder, text, extension)
        del self.env['BUILDERS']['SConfActionBuilder']
        if ok:
            outputStr = self.lastTarget.get_contents()
            return (1, outputStr)
        return (0, "")

    def TryCompile( self, text, extension):
        """Compiles the program given in text to an env.Object, using extension
        as file extension (e.g. '.c'). Returns 1, if compilation was
        successful, 0 otherwise. The target is saved in self.lastTarget (for
        further processing).
        """
        return self.TryBuild(self.env.Object, text, extension)

    def TryLink( self, text, extension ):
        """Compiles the program given in text to an executable env.Program,
        using extension as file extension (e.g. '.c'). Returns 1, if
        compilation was successful, 0 otherwise. The target is saved in
        self.lastTarget (for further processing).
        """
        return self.TryBuild(self.env.Program, text, extension )

    def TryRun(self, text, extension ):
        """Compiles and runs the program given in text, using extension
        as file extension (e.g. '.c'). Returns (1, outputStr) on success,
        (0, '') otherwise. The target (a file containing the program's stdout)
        is saved in self.lastTarget (for further processing).
        """
        ok = self.TryLink(text, extension)
        if( ok ):
            prog = self.lastTarget
            pname = str(prog)
            output = SConfFS.File(pname+'.out')
            node = self.env.Command(output, prog, [ [ pname, ">", "${TARGET}"] ])
            ok = self.BuildNodes(node)
            if ok:
                outputStr = output.get_contents()
                return( 1, outputStr)
        return (0, "")

    class TestWrapper:
        """A wrapper around Tests (to ensure sanity)"""
        def __init__(self, test, sconf):
            self.test = test
            self.sconf = sconf
        def __call__(self, *args, **kw):
            if not self.sconf.active:
                raise (SCons.Errors.UserError,
                       "Test called after sconf.Finish()")
            context = CheckContext(self.sconf)
            ret = apply(self.test, (context,) +  args, kw)
            if not self.sconf.config_h is None:
                self.sconf.config_h_text = self.sconf.config_h_text + context.config_h
            context.Result("error: no result")
            return ret

    def AddTest(self, test_name, test_instance):
        """Adds test_class to this SConf instance. It can be called with
        self.test_name(...)"""
        setattr(self, test_name, SConf.TestWrapper(test_instance, self))

    def AddTests(self, tests):
        """Adds all the tests given in the tests dictionary to this SConf
        instance
        """
        for name in tests.keys():
            self.AddTest(name, tests[name])

    def _createDir( self, node ):
        dirName = str(node)
        if dryrun:
            if not os.path.isdir( dirName ):
                raise ConfigureDryRunError(dirName)
        else:
            if not os.path.isdir( dirName ):
                os.makedirs( dirName )
                node._exists = 1

    def _startup(self):
        """Private method. Set up logstream, and set the environment
        variables necessary for a piped build
        """
        global _ac_config_logs
        global sconf_global
        global SConfFS
        
        self.lastEnvFs = self.env.fs
        self.env.fs = SConfFS
        self._createDir(self.confdir)
        self.confdir.up().add_ignore( [self.confdir] )

        if self.logfile != None and not dryrun:
            # truncate logfile, if SConf.Configure is called for the first time
            # in a build
            if _ac_config_logs.has_key(self.logfile):
                log_mode = "a"
            else:
                _ac_config_logs[self.logfile] = None
                log_mode = "w"
            self.logstream = open(str(self.logfile), log_mode)
            # logfile may stay in a build directory, so we tell
            # the build system not to override it with a eventually
            # existing file with the same name in the source directory
            self.logfile.dir.add_ignore( [self.logfile] )

            tb = traceback.extract_stack()[-3-self.depth]
            old_fs_dir = SConfFS.getcwd()
            SConfFS.chdir(SConfFS.Top, change_os_dir=0)
            self.logstream.write('file %s,line %d:\n\tConfigure(confdir = %s)\n' %
                                 (tb[0], tb[1], str(self.confdir)) )
            SConfFS.chdir(old_fs_dir)
        else: 
            self.logstream = None
        # we use a special builder to create source files from TEXT
        action = SCons.Action.Action(_createSource,
                                     _stringSource)
        sconfSrcBld = SCons.Builder.Builder(action=action)
        self.env.Append( BUILDERS={'SConfSourceBuilder':sconfSrcBld} )
        self.config_h_text = _ac_config_hs.get(self.config_h, "")
        self.active = 1
        # only one SConf instance should be active at a time ...
        sconf_global = self

    def _shutdown(self):
        """Private method. Reset to non-piped spawn"""
        global sconf_global, _ac_config_hs

        if not self.active:
            raise SCons.Errors.UserError, "Finish may be called only once!"
        if self.logstream != None and not dryrun:
            self.logstream.write("\n")
            self.logstream.close()
            self.logstream = None
        # remove the SConfSourceBuilder from the environment
        blds = self.env['BUILDERS']
        del blds['SConfSourceBuilder']
        self.env.Replace( BUILDERS=blds )
        self.active = 0
        sconf_global = None
        if not self.config_h is None:
            _ac_config_hs[self.config_h] = self.config_h_text
        self.env.fs = self.lastEnvFs

class CheckContext:
    """Provides a context for configure tests. Defines how a test writes to the
    screen and log file.

    A typical test is just a callable with an instance of CheckContext as
    first argument:

    def CheckCustom(context, ...)
    context.Message('Checking my weird test ... ')
    ret = myWeirdTestFunction(...)
    context.Result(ret)

    Often, myWeirdTestFunction will be one of
    context.TryCompile/context.TryLink/context.TryRun. The results of
    those are cached, for they are only rebuild, if the dependencies have
    changed.
    """

    def __init__(self, sconf):
        """Constructor. Pass the corresponding SConf instance."""
        self.sconf = sconf
        self.did_show_result = 0

        # for Conftest.py:
        self.vardict = {}
        self.havedict = {}
        self.headerfilename = None
        self.config_h = "" # config_h text will be stored here
        # we don't regenerate the config.h file after each test. That means,
        # that tests won't be able to include the config.h file, and so
        # they can't do an #ifdef HAVE_XXX_H. This shouldn't be a major
        # issue, though. If it turns out, that we need to include config.h
        # in tests, we must ensure, that the dependencies are worked out
        # correctly. Note that we can't use Conftest.py's support for config.h,
        # cause we will need to specify a builder for the config.h file ...

    def Message(self, text):
        """Inform about what we are doing right now, e.g.
        'Checking for SOMETHING ... '
        """
        self.Display(text)
        self.sconf.cached = 1
        self.did_show_result = 0

    def Result(self, res):
        """Inform about the result of the test. res may be an integer or a
        string. In case of an integer, the written text will be 'ok' or
        'failed'.
        The result is only displayed when self.did_show_result is not set.
        """
        if type(res) in BooleanTypes:
            if res:
                text = "yes"
            else:
                text = "no"
        elif type(res) == types.StringType:
            text = res
        else:
            raise TypeError, "Expected string, int or bool, got " + str(type(res))

        if self.did_show_result == 0:
            # Didn't show result yet, do it now.
            self.Display(text + "\n")
            self.did_show_result = 1

    def TryBuild(self, *args, **kw):
        return apply(self.sconf.TryBuild, args, kw)

    def TryAction(self, *args, **kw):
        return apply(self.sconf.TryAction, args, kw)

    def TryCompile(self, *args, **kw):
        return apply(self.sconf.TryCompile, args, kw)

    def TryLink(self, *args, **kw):
        return apply(self.sconf.TryLink, args, kw)

    def TryRun(self, *args, **kw):
        return apply(self.sconf.TryRun, args, kw)

    def __getattr__( self, attr ):
        if( attr == 'env' ):
            return self.sconf.env
        elif( attr == 'lastTarget' ):
            return self.sconf.lastTarget
        else:
            raise AttributeError, "CheckContext instance has no attribute '%s'" % attr

    #### Stuff used by Conftest.py (look there for explanations).

    def BuildProg(self, text, ext):
        self.sconf.cached = 1
        # TODO: should use self.vardict for $CC, $CPPFLAGS, etc.
        return not self.TryBuild(self.env.Program, text, ext)

    def CompileProg(self, text, ext):
        self.sconf.cached = 1
        # TODO: should use self.vardict for $CC, $CPPFLAGS, etc.
        return not self.TryBuild(self.env.Object, text, ext)

    def AppendLIBS(self, lib_name_list):
        oldLIBS = self.env.get( 'LIBS', [] )
        self.env.Append(LIBS = lib_name_list)
        return oldLIBS

    def SetLIBS(self, val):
        oldLIBS = self.env.get( 'LIBS', [] )
        self.env.Replace(LIBS = val)
        return oldLIBS

    def Display(self, msg):
        if self.sconf.cached:
            # We assume that Display is called twice for each test here
            # once for the Checking for ... message and once for the result.
            # The self.sconf.cached flag can only be set between those calls
            msg = "(cached) " + msg
            self.sconf.cached = 0
        progress_display(msg, append_newline=0)
        self.Log("scons: Configure: " + msg + "\n")

    def Log(self, msg):
        if self.sconf.logstream != None:
            self.sconf.logstream.write(msg)

    #### End of stuff used by Conftest.py.


def CheckFunc(context, function_name, header = None, language = None):
    res = SCons.Conftest.CheckFunc(context, function_name, header = header, language = language)
    context.did_show_result = 1
    return not res

def CheckType(context, type_name, includes = "", language = None):
    res = SCons.Conftest.CheckType(context, type_name,
                                        header = includes, language = language)
    context.did_show_result = 1
    return not res

def createIncludesFromHeaders(headers, leaveLast, include_quotes = '""'):
    # used by CheckHeader and CheckLibWithHeader to produce C - #include
    # statements from the specified header (list)
    if not SCons.Util.is_List(headers):
        headers = [headers]
    l = []
    if leaveLast:
        lastHeader = headers[-1]
        headers = headers[:-1]
    else:
        lastHeader = None
    for s in headers:
        l.append("#include %s%s%s\n"
                 % (include_quotes[0], s, include_quotes[1]))
    return string.join(l, ''), lastHeader

def CheckHeader(context, header, include_quotes = '<>', language = None):
    """
    A test for a C or C++ header file.
    """
    prog_prefix, hdr_to_check = \
                 createIncludesFromHeaders(header, 1, include_quotes)
    res = SCons.Conftest.CheckHeader(context, hdr_to_check, prog_prefix,
                                     language = language,
                                     include_quotes = include_quotes)
    context.did_show_result = 1
    return not res

# Bram: Make this function obsolete?  CheckHeader() is more generic.

def CheckCHeader(context, header, include_quotes = '""'):
    """
    A test for a C header file.
    """
    return CheckHeader(context, header, include_quotes, language = "C")


# Bram: Make this function obsolete?  CheckHeader() is more generic.

def CheckCXXHeader(context, header, include_quotes = '""'):
    """
    A test for a C++ header file.
    """
    return CheckHeader(context, header, include_quotes, language = "C++")


def CheckLib(context, library = None, symbol = "main",
             header = None, language = None, autoadd = 1):
    """
    A test for a library. See also CheckLibWithHeader.
    Note that library may also be None to test whether the given symbol
    compiles without flags.
    """

    if library == []:
        library = [None]

    if not SCons.Util.is_List(library):
        library = [library]
    
    # ToDo: accept path for the library
    res = SCons.Conftest.CheckLib(context, library, symbol, header = header,
                                        language = language, autoadd = autoadd)
    context.did_show_result = 1
    return not res

# XXX
# Bram: Can only include one header and can't use #ifdef HAVE_HEADER_H.

def CheckLibWithHeader(context, libs, header, language,
                       call = None, autoadd = 1):
    # ToDo: accept path for library. Support system header files.
    """
    Another (more sophisticated) test for a library.
    Checks, if library and header is available for language (may be 'C'
    or 'CXX'). Call maybe be a valid expression _with_ a trailing ';'.
    As in CheckLib, we support library=None, to test if the call compiles
    without extra link flags.
    """
    prog_prefix, dummy = \
                 createIncludesFromHeaders(header, 0)
    if libs == []:
        libs = [None]

    if not SCons.Util.is_List(libs):
        libs = [libs]

    res = SCons.Conftest.CheckLib(context, libs, None, prog_prefix,
            call = call, language = language, autoadd = autoadd)
    context.did_show_result = 1
    return not res
