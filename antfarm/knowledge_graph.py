import time
import logging
from collections import deque

class GraphNode:
    def __init__(self, node_id, node_type, name, properties=None):
        self.node_id = node_id
        self.node_type = node_type  # "dwarf", "artifact", "site", "event"
        self.name = name
        self.properties = properties or {}
        
    def to_dict(self):
        return {
            "node_id": self.node_id,
            "node_type": self.node_type,
            "name": self.name,
            "properties": self.properties
        }

class GraphEdge:
    def __init__(self, source_id, target_id, rel_type, strength=100, properties=None):
        self.source_id = source_id
        self.target_id = target_id
        self.rel_type = rel_type  # "spouse", "parent", "friend", "enemy", "killed"
        self.strength = strength  # 0 to 100
        self.properties = properties or {}
        self.timestamp = time.time()

    def to_dict(self):
        return {
            "source_id": self.source_id,
            "target_id": self.target_id,
            "rel_type": self.rel_type,
            "strength": self.strength,
            "properties": self.properties,
            "timestamp": self.timestamp
        }

class SimulationKnowledgeGraph:
    def __init__(self):
        self.nodes = {}
        self.edges = {}  # source_id -> list of GraphEdge
        self.incoming_edges = {} # target_id -> list of GraphEdge
        
    def add_node(self, node_id, node_type, name, properties=None):
        node = GraphNode(node_id, node_type, name, properties)
        self.nodes[node_id] = node
        return node
        
    def add_edge(self, source_id, target_id, rel_type, strength=100, properties=None):
        # Ensure nodes exist
        if source_id not in self.nodes:
            self.add_node(source_id, "unknown", f"ID-{source_id}")
        if target_id not in self.nodes:
            self.add_node(target_id, "unknown", f"ID-{target_id}")
            
        edge = GraphEdge(source_id, target_id, rel_type, strength, properties)
        
        # Add to outgoing edges
        if source_id not in self.edges:
            self.edges[source_id] = []
        # Deduplicate edge types
        self.edges[source_id] = [e for e in self.edges[source_id] if not (e.target_id == target_id and e.rel_type == rel_type)]
        self.edges[source_id].append(edge)
        
        # Add to incoming edges
        if target_id not in self.incoming_edges:
            self.incoming_edges[target_id] = []
        self.incoming_edges[target_id] = [e for e in self.incoming_edges[target_id] if not (e.source_id == source_id and e.rel_type == rel_type)]
        self.incoming_edges[target_id].append(edge)
        
        return edge
        
    def get_node(self, node_id):
        return self.nodes.get(node_id)
        
    def get_neighbors(self, node_id, direction="both"):
        neighbors = []
        
        if direction in ["outgoing", "both"] and node_id in self.edges:
            for edge in self.edges[node_id]:
                neighbors.append((edge.rel_type, self.nodes.get(edge.target_id), edge.strength))
                
        if direction in ["incoming", "both"] and node_id in self.incoming_edges:
            for edge in self.incoming_edges[node_id]:
                neighbors.append((f"rev_{edge.rel_type}", self.nodes.get(edge.source_id), edge.strength))
                
        return neighbors
        
    def get_relationship_strength(self, source_id, target_id, rel_type):
        if source_id in self.edges:
            for edge in self.edges[source_id]:
                if edge.target_id == target_id and edge.rel_type == rel_type:
                    return edge.strength
        return 0
        
    def update_relationship_strength(self, source_id, target_id, rel_type, delta):
        # Find edge and adjust strength
        if source_id in self.edges:
            for edge in self.edges[source_id]:
                if edge.target_id == target_id and edge.rel_type == rel_type:
                    edge.strength = max(0, min(100, edge.strength + delta))
                    return edge.strength
        return 0
        
    def remove_node(self, node_id):
        """Forget a node and every edge touching it.

        Dwarves die and migrants leave. Without this they stayed in the graph
        forever and went on counting towards the relationship centrality of
        everyone still alive, so a dwarf whose family had all died scored as
        the most connected person in the fortress.
        """
        self.nodes.pop(node_id, None)

        for edge in self.edges.pop(node_id, []):
            incoming = self.incoming_edges.get(edge.target_id)
            if incoming:
                self.incoming_edges[edge.target_id] = [
                    e for e in incoming if e.source_id != node_id
                ]
        for edge in self.incoming_edges.pop(node_id, []):
            outgoing = self.edges.get(edge.source_id)
            if outgoing:
                self.edges[edge.source_id] = [
                    e for e in outgoing if e.target_id != node_id
                ]

    def prune_to(self, live_ids):
        """Drop every dwarf node whose id is not in `live_ids`.

        Only "dwarf" nodes are pruned: artifacts, sites and event nodes are
        history and outlive the people involved in them.
        """
        stale = [
            node_id for node_id, node in self.nodes.items()
            if node.node_type == "dwarf" and node_id not in live_ids
        ]
        for node_id in stale:
            self.remove_node(node_id)
        return len(stale)

    def find_shortest_path(self, start_id, end_id, max_depth=3):
        # BFS path finder. deque, not a list: list.pop(0) is O(n) and made the
        # search quadratic in the size of the frontier.
        if start_id == end_id:
            return [start_id]

        queue = deque([[start_id]])
        visited = {start_id}

        while queue:
            path = queue.popleft()
            node = path[-1]
            
            if len(path) > max_depth + 1:
                continue
                
            if node == end_id:
                return path
                
            # Get neighbors node IDs
            neighbors = []
            if node in self.edges:
                for edge in self.edges[node]:
                    neighbors.append(edge.target_id)
            if node in self.incoming_edges:
                for edge in self.incoming_edges[node]:
                    neighbors.append(edge.source_id)
                    
            for neighbor in neighbors:
                if neighbor not in visited:
                    visited.add(neighbor)
                    new_path = list(path)
                    new_path.append(neighbor)
                    queue.append(new_path)
                    
        return None
