# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

The supplied implementation workflow keeps repository preparation on the host and supports read-only
Git metadata during Codex turns. Workers leave source changes and validation evidence for In Review;
commit, push, PR creation, merge, and deployment belong to a separate host/human-approved delivery phase.

After independent review, the [Human Acceptance evidence pack](elixir/docs/human-acceptance.md)
turns a supplied evidence snapshot into one compact Linear comment with change shape, tests,
review verdict, risks, and the exact acceptance target. Missing evidence stays explicit.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board and spawns agents to implement tasks and provide evidence. The supplied implementation workflow hands source changes and validation results to reviewers at In Review._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

An opt-in [dedicated Discovery lane](docs/discovery-worker-lane.md) validates issues before Todo using the installed Discovery Gate contract and read-only app-server sessions.
