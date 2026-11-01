# Embeds

The whole launch plan:

```nexus
file: Maps/Launch plan.nexusjson
```

Its second canvas, linked by name:

```nexus
file: [[Launch plan.nexusjson]]
canvas: Roadmap
height: 260
```

One branch, framed:

```nexus
file: Maps/Launch plan.nexusjson
topic: Launch plan > Pricing
height: 260
```

A package, every topic unfolded:

```nexus
file: Plan.nexus
layout: everything
```

A map that isn't there:

```nexus
file: Maps/Nowhere.nexusjson
```

A block without a file:

```nexus
canvas: Roadmap
```

A height that isn't one:

```nexus
file: Maps/Launch plan.nexusjson
height: tall
```
