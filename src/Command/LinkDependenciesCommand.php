<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\Platform\ContiniousIntegrationScripts\Command;

use Github\Client;
use Ibexa\Platform\ContiniousIntegrationScripts\Helper\ComposerHelper;
use Ibexa\Platform\ContiniousIntegrationScripts\ValueObject\ComposerPullRequestData;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\Serializer\Encoder\JsonEncoder;
use Symfony\Component\Serializer\Normalizer\ObjectNormalizer;
use Symfony\Component\Serializer\Serializer;

class LinkDependenciesCommand extends Command
{
    public const DEPENDENCIES_FILE = 'dependencies.json';

    /** @var ?string */
    private $token;

    /** @var \Symfony\Component\Serializer\Serializer */
    private $serializer;

    /** @var string[] */
    private $pullRequestUrls;

    public function __construct()
    {
        parent::__construct();
        $this->serializer = new Serializer([new ObjectNormalizer()], [new JsonEncoder()]);
    }

    public function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);

        $this->token = $input->getArgument('token');

        $pullRequestsData = [];
        foreach ($this->pullRequestUrls as $pullRequestUrl) {
            $pullRequestsData[] = $this->getPullRequestData($pullRequestUrl);
        }

        $this->createDependenciesFile($pullRequestsData, $io);

        return Command::SUCCESS;
    }

    protected function configure(): void
    {
        $this
            ->setName('dependencies:link')
            ->setDescription(sprintf('Outputs a %s file that contains data about related Pull Requests', self::DEPENDENCIES_FILE))
            ->addArgument('token', InputArgument::OPTIONAL, 'GitHub OAuth token')
        ;
    }

    private function getPullRequestData(string $pullRequestURL): ComposerPullRequestData
    {
        $matches = [];
        preg_match('/.*github.com\/(.*)\/(.*)\/pull\/(\d+).*/', $pullRequestURL, $matches);
        [, $owner, $repository, $prNumber] = $matches;

        if ($repository === "recipes") {
            throw new \RuntimeException('Symfony Flex recipes are not supported as dependencies. Please consult QA team what can be done in this case.');
        }

        $client = new Client();
        if ($this->token) {
            $client->authenticate($this->token, null, Client::AUTH_ACCESS_TOKEN);
        }

        $pullRequestDetails = $client->pullRequests()->show($owner, $repository, $prNumber);

        $pullRequestData = new ComposerPullRequestData();
        $pullRequestData->repositoryUrl = $pullRequestDetails['head']['repo']['html_url'];
        $pullRequestData->privateRepository = $pullRequestDetails['head']['repo']['private'];
        $branchName = $pullRequestDetails['head']['ref'];
        $targetBranch = $pullRequestDetails['base']['ref'];

        $composerData = json_decode($client->repos()->contents()->download($owner, $repository, 'composer.json', $targetBranch), true);

        $aliases = array_keys($composerData['extra']['branch-alias']);
        $branchAlias = $composerData['extra']['branch-alias'][$aliases[0]];

        $pullRequestData->package = $composerData['name'];
        $pullRequestData->requirement = sprintf('dev-%s as %s', $branchName, $branchAlias);

        return $pullRequestData;
    }

    protected function interact(InputInterface $input, OutputInterface $output): void
    {
        $io = new SymfonyStyle($input, $output);

        if (!$input->getArgument('token')) {
            $input->setArgument('token', ComposerHelper::getGitHubToken());
        }

        $relatedPRsNumber = $io->ask('Please enter the number of related Pull Requests', '1', static function ($number) {
            if (!is_numeric($number) || $number < 1) {
                throw new \RuntimeException('Positive integer expected.');
            }

            return (int) $number;
        });

        $pullRequestUrls = [];
        for ($i = 0; $i < $relatedPRsNumber; ++$i) {
            $pullRequestUrls[] = $io->ask('Link to GitHub PR', null, static function ($answer) {
                if (!is_string($answer) || !str_contains($answer, 'github.com')) {
                    throw new \RuntimeException(
                        'Link to Pull Request on GitHub expected. Example: https://github.com/ibexa/recipes/pull/22'
                    );
                }

                return $answer;
            });
        }

        $this->pullRequestUrls = array_unique($pullRequestUrls);
    }

    /**
     * @param \Ibexa\Platform\ContiniousIntegrationScripts\ValueObject\ComposerPullRequestData[] $pullRequestsData
     */
    private function createDependenciesFile(array $pullRequestsData, SymfonyStyle $io): void
    {
        $jsonContent = $this->serializer->serialize($pullRequestsData, 'json', ['json_encode_options' => JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT]);
        file_put_contents(self::DEPENDENCIES_FILE, $jsonContent);
        $io->success(sprintf('Successfully generated %s file', self::DEPENDENCIES_FILE));
    }
}
