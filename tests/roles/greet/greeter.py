"""A library made available to Ansible through `ansible_playbook.deps`."""


def greet(name: str) -> str:
    """Produce a greeting.

    Args:
        name: Who to greet.

    Returns:
        The greeting.
    """
    return f"hello, {name}"
