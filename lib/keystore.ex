defmodule Keystore do
  @moduledoc """
  [ERC-2335](https://eips.ethereum.org/EIPS/eip-2335) compliant keystore.
  """

  @secret_key_bytes 32
  @salt_bytes 32
  @derived_key_size 32
  @iv_size 16
  @checksum_message_size 32

  fields = [
    :pubkey,
    :privkey,
    :path,
    :readonly
  ]

  @enforce_keys fields
  defstruct fields

  @type t() :: %__MODULE__{
          pubkey: Bls.pubkey(),
          privkey: Bls.privkey(),
          path: String.t(),
          readonly: boolean()
        }

  require Logger

  @doc """
  Get validator keystores from the keystore directory.
  This function expects two files for each validator:
    - <keystore_dir>/<public_key>.json
    - <keystore_pass_dir>/<public_key>.txt
  """
  @spec decode_validator_keystores(binary(), binary()) :: list(t())
  def decode_validator_keystores(keystore_dir, keystore_pass_dir)
      when is_nil(keystore_dir) or is_nil(keystore_pass_dir),
      do: []

  def decode_validator_keystores(keystore_dir, keystore_pass_dir)
      when is_binary(keystore_dir) and is_binary(keystore_pass_dir) do
    keystore_dir
    |> File.ls!()
    |> Enum.flat_map(&paths_from_filename(keystore_dir, keystore_pass_dir, &1, Path.extname(&1)))
    |> Enum.flat_map(&decode_key/1)
  end

  defp paths_from_filename(keystore_dir, keystore_pass_dir, filename, ".json") do
    basename = Path.basename(filename, ".json")

    keystore_file = Path.join(keystore_dir, "#{basename}.json")
    keystore_pass_file = Path.join(keystore_pass_dir, "#{basename}.txt")

    [{keystore_file, keystore_pass_file}]
  end

  defp paths_from_filename(_keystore_dir, _keystore_pass_dir, basename, _ext) do
    Logger.warning("[Keystore] Skipping file: #{basename}. Not a json keystore file.")
    []
  end

  defp decode_key({keystore_file, keystore_pass_file}) do
    # TODO: remove `try` and handle errors properly
    [Keystore.decode_from_files!(keystore_file, keystore_pass_file)]
  rescue
    error ->
      Logger.error(
        "[Keystore] Failed to decode keystore file: #{keystore_file}. Pass file: #{keystore_pass_file} Error: #{inspect(error)}"
      )

      []
  end

  @spec decode_from_files!(Path.t(), Path.t()) :: t()
  def decode_from_files!(json, password) do
    password = File.read!(password)
    File.read!(json) |> decode_str!(password)
  end

  @spec decode_str!(String.t(), String.t()) :: t()
  def decode_str!(json, password) do
    decoded_json = Jason.decode!(json)
    # We only support version 4 (the only one)
    %{"version" => 4} = decoded_json
    path = decoded_json["path"]
    validate_empty_path!(path)

    privkey = decrypt!(decoded_json["crypto"], password)

    {:ok, derived_pubkey} = Bls.derive_pubkey(privkey)

    pubkey =
      case Map.has_key?(decoded_json, "pubkey") do
        true -> Map.get(decoded_json, "pubkey") |> parse_binary!()
        false -> derived_pubkey
      end

    if derived_pubkey != pubkey do
      raise("Keystore secret and public keys don't form a valid pair")
    end

    %__MODULE__{pubkey: pubkey, privkey: privkey, path: path, readonly: false}
  end

  # TODO: support keystore paths
  defp validate_empty_path!(path) when byte_size(path) > 0,
    do: raise("Only empty-paths are supported")

  defp validate_empty_path!(_), do: :ok

  defp decrypt!(%{"kdf" => kdf, "checksum" => checksum, "cipher" => cipher}, password) do
    password = sanitize_password(password)
    derived_key = derive_key!(kdf, password)

    {iv, cipher_message} = parse_cipher!(cipher)
    checksum_message = parse_checksum!(checksum)
    verify_password!(derived_key, cipher_message, checksum_message)
    secret = decrypt_secret(derived_key, iv, cipher_message)

    if byte_size(secret) != @secret_key_bytes do
      raise "Invalid secret length: #{byte_size(secret)}"
    end

    secret
  end

  defp derive_key!(%{"function" => "scrypt", "params" => params}, password) do
    %{"dklen" => @derived_key_size, "salt" => hex_salt, "n" => n, "p" => p, "r" => r} = params
    salt = parse_binary!(hex_salt)

    if byte_size(salt) != @salt_bytes do
      raise "Invalid salt size: #{byte_size(salt)}"
    end

    log_n = n |> :math.log2() |> trunc()
    Scrypt.hash(password, salt, log_n, r, p, @derived_key_size)
  end

  defp derive_key!(%{"function" => "pbkdf2", "params" => params}, password) do
    %{"dklen" => dklen, "salt" => hex_salt, "c" => c, "prf" => "hmac-sha256"} = params
    salt = parse_binary!(hex_salt)

    if byte_size(salt) != @salt_bytes do
      raise "Invalid salt size: #{byte_size(salt)}"
    end

    :crypto.pbkdf2_hmac(:sha256, password, salt, c, dklen)
  end

  defp decrypt_secret(derived_key, iv, cipher_message) do
    <<key::binary-size(16), _::binary>> = derived_key
    :crypto.crypto_one_time(:aes_128_ctr, key, iv, cipher_message, false)
  end

  defp verify_password!(derived_key, cipher_message, checksum_message) do
    dk_slice = derived_key |> binary_part(16, 16)

    pre_image = dk_slice <> cipher_message
    checksum = :crypto.hash(:sha256, pre_image)

    if checksum != checksum_message do
      raise "Invalid password"
    end
  end

  defp parse_checksum!(%{"function" => "sha256", "message" => hex_message}) do
    message = parse_binary!(hex_message)

    if byte_size(message) != @checksum_message_size do
      "Invalid checksum size: #{byte_size(message)}"
    end

    message
  end

  defp parse_cipher!(%{
         "function" => "aes-128-ctr",
         "params" => %{"iv" => hex_iv},
         "message" => hex_message
       }) do
    iv = parse_binary!(hex_iv)

    if byte_size(iv) != @iv_size do
      raise "Invalid IV size: #{byte_size(iv)}"
    end

    {iv, parse_binary!(hex_message)}
  end

  defp parse_binary!(hex), do: Base.decode16!(hex, case: :mixed)

  defp sanitize_password(password),
    do: password |> String.normalize(:nfkd) |> String.replace(~r/[\x00-\x1f\x80-\x9f\x7f]/, "")

  def keystore_file(base_name) do
    config =
      Application.get_env(:lambda_ethereum_consensus, LambdaEthereumConsensus.Validator.Setup, [])

    keystore_dir = Keyword.get(config, :keystore_dir) || "keystore_dir"
    Path.join(keystore_dir, base_name <> ".json")
  end

  def keystore_pass_file(base_name) do
    config =
      Application.get_env(:lambda_ethereum_consensus, LambdaEthereumConsensus.Validator.Setup, [])

    keystore_pass_dir = Keyword.get(config, :keystore_pass_dir) || "keystore_pass_dir"
    Path.join(keystore_pass_dir, base_name <> ".txt")
  end
end
