# Multi-Mermaid Heavy Document（R-M4 测试）

> 此文档含 12 个 Mermaid 图，用于 S-003 验证多图表场景下增量更新的重渲染闪烁（R-M4）。

## 1. 流程图
```mermaid
graph LR
    A --> B --> C
```

## 2. 时序图
```mermaid
sequenceDiagram
    A->>B: req
    B-->>A: res
```

## 3. 甘特图
```mermaid
gantt
    title P
    dateFormat X
    section S1
    t1 :0, 3
```

## 4. 类图
```mermaid
classDiagram
    class X { +a: int }
```

## 5. 状态图
```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Active: start
```

## 6. 饼图
```mermaid
pie title Pets
    "Dogs" : 50
    "Cats" : 50
```

## 7. 流程图 2
```mermaid
graph TD
    X --> Y
```

## 8. 时序图 2
```mermaid
sequenceDiagram
    C->>D: ping
```

## 9. 甘特图 2
```mermaid
gantt
    title Q
    dateFormat X
    section S2
    t2 :0, 2
```

## 10. 类图 2
```mermaid
classDiagram
    class Y { +b: int }
```

## 11. 状态图 2
```mermaid
stateDiagram-v2
    [*] --> On
```

## 12. 饼图 2
```mermaid
pie title OS
    "macOS" : 100
```
