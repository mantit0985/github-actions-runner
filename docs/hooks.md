# Controller Hook Contract

| Hook Name | Trigger Point | Expected Payload Shape |
|-----------|---------------|------------------------|
| `pre-register` | Before runner registration | `{}` |
| `post-job` | After job completion | `{}` |
| `drain` | When draining jobs | `{}` |
| `scale` | When scaling event occurs | `{}` |

## Cross-Reference

Fleet-level acceptance (docker stack deploy, N runners, autolock, secrets posture, placement constraints with node.labels.t) belongs to the containers design paper — out of this repo.
