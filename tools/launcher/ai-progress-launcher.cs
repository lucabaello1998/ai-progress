using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

// Lanzador de ai-progress: abre el widget con pwsh oculto, sin ventana de consola.
// Se compila con csc (ver tools/build-exe.ps1) y queda como ai-progress.exe.
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        string carpeta = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        string script = Path.Combine(carpeta, "ai-progress.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show(
                "No encuentro ai-progress.ps1 junto a ai-progress.exe.\n\n" +
                "Copiá el .exe dentro de la carpeta del proyecto.",
                "ai-progress", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string pwsh = BuscarPwsh();
        if (pwsh == null)
        {
            MessageBox.Show(
                "Falta PowerShell 7.\n\n" +
                "Instalalo con:\n    winget install Microsoft.PowerShell\n\n" +
                "Después volvé a abrir ai-progress.",
                "ai-progress", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        var inicio = new ProcessStartInfo(
            pwsh,
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"");
        inicio.UseShellExecute = false;
        inicio.CreateNoWindow = true;
        inicio.WorkingDirectory = carpeta;
        try
        {
            Process.Start(inicio);
        }
        catch (Exception error)
        {
            MessageBox.Show(
                "No pude iniciar el widget:\n" + error.Message,
                "ai-progress", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static string BuscarPwsh()
    {
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string programas = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string programasX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string[] candidatos = new string[] {
            Path.Combine(local, @"Microsoft\WindowsApps\pwsh.exe"),
            Path.Combine(programas, @"PowerShell\7\pwsh.exe"),
            Path.Combine(programasX86, @"PowerShell\7\pwsh.exe"),
        };
        foreach (string candidato in candidatos)
        {
            if (File.Exists(candidato)) return candidato;
        }
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string parte in path.Split(';'))
        {
            if (parte.Trim().Length == 0) continue;
            try
            {
                string candidato = Path.Combine(parte.Trim(), "pwsh.exe");
                if (File.Exists(candidato)) return candidato;
            }
            catch (ArgumentException) { }
        }
        return null;
    }
}
