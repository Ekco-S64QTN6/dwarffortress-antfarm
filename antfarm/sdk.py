import os
import importlib.util
import logging

class BasePlugin:
    """
    Base Plugin interface for the Simulation Observability Platform SDK.
    All plugins should inherit from this class and override the hook methods.
    """
    def __init__(self, name, version="1.0.0"):
        self.name = name
        self.version = version
        self.enabled = True
        
    def on_load(self, event_bus, knowledge_graph):
        """Called when the plugin is loaded by the manager."""
        pass
        
    def on_unload(self):
        """Called when the plugin is unloaded."""
        pass
        
    def on_event(self, event):
        """Hook to react to events dispatched on the Event Bus."""
        pass
        
    def on_tick(self, state):
        """Hook to react to regular state checks."""
        pass
        
    def register_widget(self):
        """Expose custom Textual/OBS UI widgets if applicable."""
        return None
        
    def register_scene(self):
        """Expose custom Director AI camera scenes if applicable."""
        return None

class PluginManager:
    def __init__(self, event_bus, knowledge_graph):
        self.event_bus = event_bus
        self.knowledge_graph = knowledge_graph
        self.plugins = {}
        
    def register_plugin(self, plugin: BasePlugin):
        old = self.plugins.get(plugin.name)
        if old is not None:
            logging.warning(f"Plugin {plugin.name} is already registered. Overwriting.")

        # Subscribe the replacement BEFORE unsubscribing the one it replaces, so
        # a hot-reload cannot drop events that arrive in between. Both are
        # briefly live, which is the harmless direction to fail in.
        self.plugins[plugin.name] = plugin
        plugin.on_load(self.event_bus, self.knowledge_graph)
        self.event_bus.subscribe("*", plugin.on_event)

        if old is not None:
            self.event_bus.unsubscribe("*", old.on_event)
            try:
                old.on_unload()
            except Exception as e:
                logging.error(f"Plugin {old.name} on_unload failed: {e}")

        logging.info(f"Loaded Plugin: {plugin.name} (v{plugin.version})")
        
    def unload_plugin(self, name):
        if name in self.plugins:
            plugin = self.plugins.pop(name)
            self.event_bus.unsubscribe("*", plugin.on_event)
            plugin.on_unload()
            logging.info(f"Unloaded Plugin: {name}")
            
    def load_plugins_from_directory(self, directory_path):
        """
        Dynamically imports and registers plugins from a target folder.
        Expects directory containing Python files exporting a 'Plugin' class inheriting from BasePlugin.

        Each file is loaded from its path with importlib rather than by putting
        the plugin directory on sys.path. The old approach prepended the
        directory permanently, so a plugin named json.py, os.py or threading.py
        shadowed that stdlib module for the whole process -- for every import
        after it, anywhere in the program.
        """
        if not os.path.exists(directory_path):
            logging.warning(f"Plugin directory {directory_path} does not exist.")
            return

        for filename in sorted(os.listdir(directory_path)):
            if not filename.endswith(".py") or filename.startswith("__"):
                continue
            module_name = filename[:-3]
            path = os.path.join(directory_path, filename)
            try:
                # A namespaced module name keeps a plugin out of sys.modules'
                # top level, where it could still be picked up by a plain
                # `import <name>` elsewhere.
                spec = importlib.util.spec_from_file_location(
                    f"antfarm_plugins.{module_name}", path)
                if spec is None or spec.loader is None:
                    logging.error(f"Failed to load plugin {module_name}: no import spec")
                    continue
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)

                plugin_class = getattr(module, "Plugin", None)
                if isinstance(plugin_class, type) and issubclass(plugin_class, BasePlugin):
                    self.register_plugin(plugin_class())
                else:
                    logging.warning(f"File {filename} does not export a valid 'Plugin' subclass.")
            except Exception as e:
                logging.error(f"Failed to load plugin {module_name}: {e}")
