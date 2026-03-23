## Docker / Benchmarking
- SPECIFICALLY FOR BENCHMARKING, use tmux to attach to a persistent Docker container for profiling/benchmarking
- Start container: `docker run -d --privileged --name bench ... sleep infinity`
- Attach: `tmux new-session -d -s bench "docker exec -it bench bash"`
- Keep the container alive between runs
