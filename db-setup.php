<?php
/**
 * Root entry for DB setup (Hostinger-friendly).
 * Some nginx configs return HTTP 405 for POST under /api/.
 */
require __DIR__ . '/api/db-config.php';
