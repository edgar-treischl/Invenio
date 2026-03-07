"""WSGI entry point for the InvenioRDM UI application."""
from invenio_app.factory import create_ui

application = create_ui()
