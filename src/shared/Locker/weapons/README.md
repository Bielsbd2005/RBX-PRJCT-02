Contenido gestionado en Studio, NO por Rojo.

Los items del locker se añaden y editan directamente en el place: Rojo crea esta
carpeta vacía (init.meta.json → ignoreUnknownInstances) y no toca lo que haya
dentro. Los .rbxm que vivían aquí se borraron al migrar; `globIgnorePaths`
(default.project.json) evita que un .rbxm suelto vuelva a sincronizarse.
