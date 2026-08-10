# Flowchart Sample

```mermaid
graph TD
    A[Start] --> B{Is valid?}
    B -->|Yes| C[Process]
    B -->|No| D[Show Error]
    C --> E[Save]
    D --> E
    E --> F[End]
```
