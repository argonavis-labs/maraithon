# Run only in the existing Cloud Run eval job. No plaintext request or response
# enters CI logs; the operator retains the matching private key outside the repo.
Application.load(:maraithon)
{:ok, _} = Application.ensure_all_started(:public_key)
{:ok, vault} = Maraithon.Vault.start_link([])

try do
  [entry] =
    System.fetch_env!("DELEGATION_EVAL_REVIEW_PUBLIC_KEY")
    |> Base.decode64!()
    |> :public_key.pem_decode()

  key = :public_key.pem_entry_decode(entry)
  {:RSAPublicKey, modulus, _exponent} = key
  true = bit_size(:binary.encode_unsigned(modulus)) >= 2048

  {:ok, review, _} =
    Ecto.Migrator.with_repo(Maraithon.Repo, fn _ ->
      [report] =
        Maraithon.Delegations.EvaluationRunner.status(
          System.fetch_env!("DELEGATION_EVAL_JOB_ID")
        )

      [runtime | _] = report.details.proposal_runtime
      step_id = runtime.last_proposal_review.step_id

      step =
        Maraithon.Repo.get_by!(Maraithon.Agents.AgentRunStep,
          id: step_id,
          agent_id: runtime.agent_id
        )
        |> Maraithon.Agents.AgentRunStep.hydrate_payloads!()

      %{
        step_id: step.id,
        request: step.request_payload,
        response: step.response_payload
      }
    end)

  # 190 bytes fits RSA-OAEP with SHA-1 even for the smallest accepted key.
  chunks =
    review
    |> Jason.encode!()
    |> :zlib.gzip()
    |> Stream.unfold(fn
      "" -> nil
      data ->
        size = min(byte_size(data), 190)
        <<chunk::binary-size(size), rest::binary>> = data
        {chunk, rest}
    end)
    |> Enum.map(fn chunk ->
      :public_key.encrypt_public(chunk, key, rsa_padding: :rsa_pkcs1_oaep_padding)
      |> Base.encode64()
    end)

  IO.puts("DELEGATION_EVAL_ENCRYPTED=" <> Jason.encode!(%{chunks: chunks}))
after
  GenServer.stop(vault)
end
