using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Windows.Forms;

namespace AiProgressHost
{
    // .exe autocontenido: trae el runtime de .NET + PowerShell SDK, extrae el script embebido
    // y lo corre en el mismo proceso (sin exigir PowerShell 7 instalado).
    internal static class Program
    {
        [STAThread]
        private static int Main()
        {
            string carpeta = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ai-progress", "runtime");
            string assets = Path.Combine(carpeta, "assets");
            Directory.CreateDirectory(assets);

            string script = Path.Combine(carpeta, "ai-progress.ps1");
            string icono = Path.Combine(assets, "ai-progress.ico");
            try
            {
                Extraer("ai-progress.ps1", script);
                Extraer("ai-progress.ico", icono);
            }
            catch (Exception error)
            {
                return Fallar(carpeta, error);
            }

            // El runtime de PowerShell busca los modulos built-in en la carpeta de extraccion del
            // .exe single-file; los copiamos ahi la primera vez (vienen al lado del .exe).
            PrepararModulos();

            // El script resuelve config/status/icono contra esta carpeta y sabe que .exe
            // usar para el arranque con Windows.
            Environment.SetEnvironmentVariable("AI_PROGRESS_DIR", carpeta);
            Environment.SetEnvironmentVariable("AI_PROGRESS_EXE", Environment.ProcessPath);

            try
            {
                // CreateDefault2 evita la carga de snap-ins (CreateDefault falla en un host
                // self-contained/single-file porque no hay PSHOME).
                InitialSessionState estado = InitialSessionState.CreateDefault2();
                using (Runspace runspace = RunspaceFactory.CreateRunspace(estado))
                {
                    // WPF necesita STA: el pipeline corre en el hilo principal ([STAThread]).
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.ApartmentState = System.Threading.ApartmentState.STA;
                    runspace.Open();
                    using (PowerShell ps = PowerShell.Create())
                    {
                        ps.Runspace = runspace;
                        ps.AddScript(File.ReadAllText(script));
                        ps.Invoke();
                        if (ps.HadErrors && ps.Streams.Error.Count > 0)
                        {
                            string log = Path.Combine(carpeta, "error.log");
                            using (StreamWriter salida = new StreamWriter(log, false))
                            {
                                foreach (ErrorRecord registro in ps.Streams.Error)
                                {
                                    salida.WriteLine(registro.ToString());
                                }
                            }
                        }
                    }
                }
            }
            catch (Exception error)
            {
                return Fallar(carpeta, error);
            }
            return 0;
        }

        private static void PrepararModulos()
        {
            string psBase = Path.GetDirectoryName(typeof(PSObject).Assembly.Location);
            if (string.IsNullOrEmpty(psBase)) return;
            string destino = Path.Combine(psBase, "Modules");
            if (Directory.Exists(destino)) return;

            string[] raices = new string[]
            {
                AppContext.BaseDirectory,
                Path.GetDirectoryName(Environment.ProcessPath) ?? string.Empty,
                psBase,
            };
            foreach (string raiz in raices)
            {
                if (string.IsNullOrEmpty(raiz)) continue;
                string origen = Path.Combine(raiz, "runtimes", "win", "lib", "net8.0", "Modules");
                if (Directory.Exists(origen))
                {
                    CopiarDirectorio(origen, destino);
                    return;
                }
            }
        }

        private static void CopiarDirectorio(string origen, string destino)
        {
            Directory.CreateDirectory(destino);
            foreach (string archivo in Directory.GetFiles(origen))
            {
                File.Copy(archivo, Path.Combine(destino, Path.GetFileName(archivo)), true);
            }
            foreach (string carpeta in Directory.GetDirectories(origen))
            {
                CopiarDirectorio(carpeta, Path.Combine(destino, Path.GetFileName(carpeta)));
            }
        }

        private static void Extraer(string recurso, string destino)
        {
            Assembly ensamblado = Assembly.GetExecutingAssembly();
            using (Stream entrada = ensamblado.GetManifestResourceStream(recurso))
            {
                if (entrada == null)
                {
                    throw new InvalidOperationException("Falta el recurso embebido " + recurso);
                }
                using (FileStream salida = new FileStream(destino, FileMode.Create, FileAccess.Write))
                {
                    entrada.CopyTo(salida);
                }
            }
        }

        private static int Fallar(string carpeta, Exception error)
        {
            try
            {
                File.AppendAllText(Path.Combine(carpeta, "error.log"),
                    DateTime.Now.ToString("s") + " " + error + Environment.NewLine);
            }
            catch (IOException) { }
            MessageBox.Show(
                "ai-progress no pudo arrancar:\n" + error.Message +
                "\n\nDetalle en:\n" + Path.Combine(carpeta, "error.log"),
                "ai-progress", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
