FROM ubuntu:24.04

# Prevent interactive prompts during package installations
ENV DEBIAN_FRONTEND=noninteractive

# Install PostgreSQL, pgBackRest, sudo, cron, and basic dependencies
RUN apt-get update && apt-get install -y \
    postgresql \
    postgresql-client \
    pgbackrest \
    sudo \
    cron \
    systemd-sysv \
    && rm -rf /var/lib/apt/lists/*

# Configure sudoers so postgres and root users can execute commands as each other without passwords.
# This is crucial for the automated restore script to execute sudo systemctl stop/start postgresql.
RUN echo "postgres ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
    && echo "root ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Create pgBackRest directories with correct ownership and permissions
RUN mkdir -p /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest \
    && chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest \
    && chmod 750 /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest

# Expose PostgreSQL default port
EXPOSE 5432

# Copy the entrypoint script into the image
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
