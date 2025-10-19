from pathlib import Path
from tools.workflows import update_workflows
from tools.workflows.update_workflows import load_yaml

path = Path('tmp-wf.yml')
doc = load_yaml(path)
update_workflows.ensure_wire_probes_all_jobs(doc, 'tests/results')
update_workflows.ensure_lint_resiliency(doc, 'lint', include_node=True, markdown_non_blocking=True)
update_workflows.ensure_wire_S1_before_session_index(doc)
print(doc['jobs']['lint']['steps'])
