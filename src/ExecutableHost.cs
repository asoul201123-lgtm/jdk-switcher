using System;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace SafeJdkSwitcher
{
    internal static class ExecutableHost
    {
        private static string ReadResource(string name)
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (stream == null) throw new InvalidOperationException("Missing application resource: " + name);
                using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                    return reader.ReadToEnd();
            }
        }

        private static void InvokeChecked(PowerShell shell)
        {
            shell.Invoke();
            if (shell.HadErrors)
                throw new InvalidOperationException(string.Join(Environment.NewLine,
                    shell.Streams.Error.Select(error => error.ToString()).ToArray()));
        }

        [STAThread]
        private static int Main(string[] args)
        {
            bool smokeTest = args.Contains("--smoke-test");
            try
            {
                if (args.Any(arg => arg != "--smoke-test" && arg != "--demo"))
                    throw new ArgumentException("Supported options: --demo, --smoke-test");

                // Use the Windows PowerShell engine installed with Windows. The
                // application code stays in EXE resources: no temporary scripts,
                // profile loading, command-line scripts or policy changes.
                using (Runspace runspace = RunspaceFactory.CreateRunspace())
                {
                    runspace.ApartmentState = ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.Open();
                    runspace.SessionStateProxy.SetVariable("JdkSwitcherExecutable",
                        Assembly.GetExecutingAssembly().Location);
                    using (PowerShell shell = PowerShell.Create())
                    {
                        shell.Runspace = runspace;
                        shell.AddScript("param($text) $ErrorActionPreference = 'Stop'; " +
                            "New-Module -Name JdkSwitcher.Core -ScriptBlock " +
                            "([scriptblock]::Create($text)) | Import-Module -Force")
                            .AddArgument(ReadResource("JdkSwitcher.Core.psm1"));
                        InvokeChecked(shell);
                        shell.Commands.Clear();
                        shell.Streams.Error.Clear();
                        shell.AddScript(ReadResource("App.ps1"))
                            .AddParameter("EmbeddedHost", true)
                            .AddParameter("SmokeTest", smokeTest)
                            .AddParameter("Demo", args.Contains("--demo"));
                        InvokeChecked(shell);
                    }
                }
                return 0;
            }
            catch (Exception error)
            {
                if (smokeTest) Console.Error.WriteLine(error.Message);
                else MessageBox.Show(error.Message, "JDK Switcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
