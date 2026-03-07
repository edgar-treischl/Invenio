"""WSGI entry point for the InvenioRDM REST API application."""
from invenio_app.factory import create_api

application = create_api()
