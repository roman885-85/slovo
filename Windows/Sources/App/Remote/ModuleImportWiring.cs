// =============================================================================
//  ModuleImportWiring.cs — імпорт модулів у фоні (планшет) через ядро імпорту
// =============================================================================
//  Як importModule на Mac: джерело — присланий файл, лише модулі й пісенники
//  (шаблонам і фонам із планшета взятися нізвідки), поставлене — у бібліотеку.
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public static class ModuleImportWiring
{
    public static void Install()
    {
        ModuleImport.Run = (file, state, done) =>
        {
            var destination = ImportDestination.ApplicationLibrary;
            Task.Run(() =>
            {
                ImportOutcome? outcome = null;
                string? problem = null;
                try
                {
                    var source = ModuleImporter.SourceAt(file);
                    var inventory = ModuleImporter.Inventory(source, destination);
                    inventory.Templates = new List<ImportItem>();
                    inventory.Images = new List<ImportItem>();
                    outcome = ModuleImporter.Run(inventory, destination);
                }
                catch (Exception error) { problem = error.Message; }
                var imported = outcome?.ImportedModules.ToList() ?? new List<string>();
                var modules = outcome?.Modules.ToList() ?? new List<string>();
                var failures = outcome?.Failures.Select(f => f.Reason).ToList() ?? new List<string>();
                Dispatcher.UIThread.Post(() =>
                {
                    if (problem == null && imported.Count > 0) state.AdoptImported(imported);
                    done(imported, modules, failures, problem);
                });
            });
        };
    }
}
