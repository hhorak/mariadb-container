function usage() {
  [ $# == 1 ] && echo "error: $1"
  echo "For galera replication, you have to specify following environment variables:"
  echo "  MYSQL_CLUSTER_NAME"
  echo "  MYSQL_CLUSTER_NODES or run with --wsrep-new-cluster argument"
  echo
  echo "For more information, see https://github.com/sclorg/mariadb-container"
  exit 1
}

function validate_galera_variables() {
  [[ -v MYSQL_CLUSTER_NAME ]] || usage
  [ -n "${MYSQL_CLUSTER_NODES:-}" ] || [[ "$@" =~ --wsrep-new-cluster ]] || usage "Either use --wsrep-new-cluster \
argument to initialize cluster or specify existing nodes using MYSQL_CLUSTER_NODES variable"
  [[ "$MYSQL_CLUSTER_NAME" =~ $mysql_identifier_regex ]] || usage "Invalid MYSQL_CLUSTER_NAME value, $mysql_identifier_regex expected"
}

validate_galera_variables "$@"
