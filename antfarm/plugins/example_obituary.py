"""Example plugin: log a one-line obituary whenever a citizen dies.

Copy this as a starting point. Files in this directory are auto-loaded at
engine start; delete or rename this one if you do not want it running.
"""

import logging

from antfarm.sdk import BasePlugin


class Plugin(BasePlugin):
    def __init__(self):
        super().__init__("example-obituary", "1.0.0")
        self.graph = None

    def on_load(self, event_bus, knowledge_graph):
        self.graph = knowledge_graph

    def on_event(self, event):
        if event.name != "CitizenDeath":
            return
        name = event.payload.get("name", "A dwarf")
        node = self.graph.get_node(event.payload.get("id")) if self.graph else None
        job = (node.properties.get("job") if node else None) or "unknown duties"
        logging.info(f"[obituary] {name} has died, last seen at {job}.")
