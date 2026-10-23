import logging
import sys
from app.core.config import settings


def setup_logging() -> logging.Logger:
    """Configure structured console logging for the application."""
    log_level = logging.DEBUG if settings.DEBUG else logging.INFO

    logging.basicConfig(
        level=log_level,
        format="%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[
            logging.StreamHandler(sys.stdout),
        ],
        force=True,
    )

    logger = logging.getLogger("jess_backend")
    logger.setLevel(log_level)
    return logger


logger = setup_logging()
