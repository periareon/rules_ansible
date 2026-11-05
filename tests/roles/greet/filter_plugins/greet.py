"""A filter plugin which depends on a python package from `deps`."""

from tests.roles.greet.greeter import greet


class FilterModule:
    """Ansible filter plugin entrypoint."""

    def filters(self):
        """Return the filters provided by this plugin."""
        return {"greet": greet}
