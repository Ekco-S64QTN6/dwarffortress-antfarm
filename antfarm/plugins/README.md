# Antfarm plugins

Drop a `.py` file here that exports a class named `Plugin` deriving from
`antfarm.sdk.BasePlugin`. It is loaded at engine start and receives the event bus
and the live knowledge graph.

```python
from antfarm.sdk import BasePlugin

class Plugin(BasePlugin):
    def __init__(self):
        super().__init__("my-plugin", "1.0.0")

    def on_load(self, event_bus, knowledge_graph):
        self.graph = knowledge_graph

    def on_event(self, event):        # every event on the bus
        if event.name == "CitizenDeath":
            ...

    def on_tick(self, state):         # every state frame (~5/sec)
        ...
```

Hooks: `on_load`, `on_unload`, `on_event`, `on_tick`, `register_widget`,
`register_scene`. Exceptions are logged and never take the dashboard down.
